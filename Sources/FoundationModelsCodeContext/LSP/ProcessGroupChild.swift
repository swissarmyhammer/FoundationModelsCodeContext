import Darwin
import Foundation
import Synchronization

/// A child process that leads its own process group. One signal to the group reaches the child
/// and each process that the child starts.
///
/// A language server can start child processes of its own, for example `tsserver` or the
/// proc-macro server of `rust-analyzer`. A signal to the pid of the server does not reach them,
/// and they can keep the pipes of the server open. Thus `spawn` starts the child with
/// `posix_spawn(2)` and `POSIX_SPAWN_SETPGROUP`: the child gets a new process group, whose id is
/// the pid of the child. Each process that the child starts is in the same group, unless that
/// process makes a new group. `signalGroup(_:)` sends a signal to the full group.
///
/// Foundation `Process` cannot set the process group of its child, thus this type does not use
/// it. It keeps the rule of `ProcessUtilities.makeChildProcess`: the caller gives each of the
/// three standard streams, and the child shares no standard stream with this process. As
/// `Process` does, it gives the child no other file descriptor of this process
/// (`POSIX_SPAWN_CLOEXEC_DEFAULT`), and it sets the signal mask and the signal actions of the
/// child to the defaults.
///
/// A dedicated thread waits for the exit of the child with `waitpid(2)`. Thus the child is
/// reaped, and it does not stay as a zombie. `isRunning` is `false` from the time of the reap.
final class ProcessGroupChild: Sendable {
    /// The pid of the child. The child leads its process group, thus this is also the id of the
    /// group.
    let pid: pid_t

    /// Fires when the reaper thread reaped the child.
    private let exitSignal: ExitSignal

    /// Keeps the pid and the exit signal of a child that `spawn` started.
    /// - Parameters:
    ///   - pid: The pid of the child.
    ///   - exitSignal: The signal that the reaper thread fires at the reap.
    private init(pid: pid_t, exitSignal: ExitSignal) {
        self.pid = pid
        self.exitSignal = exitSignal
    }

    /// Starts `executableURL` as the leader of a new process group, and starts the thread that
    /// reaps it.
    ///
    /// The function closes the ends of the pipes that the child uses (the read end of a standard
    /// input pipe, and the write ends of `standardOutput` and `standardError`) in this process,
    /// also when the start fails. Thus the read loops of the caller get the end of the file when
    /// the child exits.
    /// - Parameters:
    ///   - executableURL: The executable that the child runs.
    ///   - arguments: The arguments of the executable.
    ///   - standardInput: The standard input of the child: the null device, or a pipe that the
    ///     caller writes to.
    ///   - standardOutput: The pipe that gets the standard output of the child.
    ///   - standardError: The pipe that gets the standard error of the child.
    /// - Returns: The started child.
    /// - Throws: A `POSIXError` when `posix_spawn(2)` or one of its setup calls fails.
    static func spawn(
        executableURL: URL,
        arguments: [String],
        standardInput: ProcessUtilities.StandardInput,
        standardOutput: Pipe,
        standardError: Pipe
    ) throws -> ProcessGroupChild {
        defer {
            closeChildEnds(standardInput: standardInput, standardOutput: standardOutput, standardError: standardError)
        }
        var fileActions: posix_spawn_file_actions_t?
        try requireSuccess(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try addStandardStreams(
            to: &fileActions,
            standardInput: standardInput,
            standardOutput: standardOutput,
            standardError: standardError
        )

        var attributes: posix_spawnattr_t?
        try requireSuccess(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try configureNewProcessGroup(&attributes)

        let pid = try launch(
            executableURL: executableURL,
            arguments: arguments,
            fileActions: &fileActions,
            attributes: &attributes
        )
        let exitSignal = ExitSignal()
        startReaper(pid: pid, exitSignal: exitSignal)
        return ProcessGroupChild(pid: pid, exitSignal: exitSignal)
    }

    /// Whether the child did not exit yet. The value is `false` from the time that the reaper
    /// thread reaps the child.
    var isRunning: Bool {
        !exitSignal.hasFired
    }

    /// Sends `signal` to each process of the process group of the child.
    ///
    /// The group stays while one of its processes stays, also after the reap of the child.
    /// When no process of the group stays, the call does nothing.
    /// - Parameter signal: The signal to send, for example `SIGTERM` or `SIGKILL`.
    func signalGroup(_ signal: Int32) {
        _ = kill(-pid, signal)
    }

    /// Suspends until the reaper thread reaps the child, or until the task of the caller is
    /// cancelled. Returns at once when the child already exited.
    func waitUntilExit() async {
        await exitSignal.wait()
    }

    /// Stops each process of the process group, and waits for the reap of the child.
    ///
    /// Sends `SIGTERM` to the group, and waits at most `grace` for the exit of the child. Then
    /// sends `SIGKILL` to the group, also when the child exited in time: a process of the group
    /// that ignores `SIGTERM`, or that the exit of the child did not stop, must also stop. Then
    /// waits for the reap.
    /// - Parameter grace: The time that the child gets to exit after `SIGTERM`.
    func terminateGroup(grace: Duration) async {
        signalGroup(SIGTERM)
        await waitUntilExit(atMost: grace)
        signalGroup(SIGKILL)
        await waitUntilExit()
    }

    /// Suspends until the reap of the child, or until `limit` elapses.
    /// - Parameter limit: The longest time to wait.
    private func waitUntilExit(atMost limit: Duration) async {
        let exitSignal = self.exitSignal
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await exitSignal.wait() }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Spawn steps

    /// Throws a `POSIXError` when `result`, the return value of a `posix_spawn` call, is not
    /// zero.
    /// - Parameter result: Zero, or an error number.
    /// - Throws: A `POSIXError` for the error number.
    private static func requireSuccess(_ result: Int32) throws {
        guard result != .zero else { return }
        throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL)
    }

    /// Adds the file actions that give the child its three standard streams.
    /// - Parameters:
    ///   - fileActions: The file actions of the spawn.
    ///   - standardInput: The null device, or a pipe whose read end the child reads.
    ///   - standardOutput: The pipe whose write end the child writes its standard output to.
    ///   - standardError: The pipe whose write end the child writes its standard error to.
    /// - Throws: A `POSIXError` when a file action cannot be added.
    private static func addStandardStreams(
        to fileActions: inout posix_spawn_file_actions_t?,
        standardInput: ProcessUtilities.StandardInput,
        standardOutput: Pipe,
        standardError: Pipe
    ) throws {
        switch standardInput {
        case .nullDevice:
            try requireSuccess(
                posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, .zero)
            )
        case .pipe(let pipe):
            let readEnd = pipe.fileHandleForReading.fileDescriptor
            try requireSuccess(posix_spawn_file_actions_adddup2(&fileActions, readEnd, STDIN_FILENO))
        }
        let outputWriteEnd = standardOutput.fileHandleForWriting.fileDescriptor
        try requireSuccess(posix_spawn_file_actions_adddup2(&fileActions, outputWriteEnd, STDOUT_FILENO))
        let errorWriteEnd = standardError.fileHandleForWriting.fileDescriptor
        try requireSuccess(posix_spawn_file_actions_adddup2(&fileActions, errorWriteEnd, STDERR_FILENO))
    }

    /// Sets the attributes that put the child in a new process group, give it only the file
    /// descriptors of the file actions, and set its signal mask and signal actions to the
    /// defaults.
    /// - Parameter attributes: The attributes of the spawn.
    /// - Throws: A `POSIXError` when an attribute cannot be set.
    private static func configureNewProcessGroup(_ attributes: inout posix_spawnattr_t?) throws {
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        try requireSuccess(posix_spawnattr_setflags(&attributes, Int16(flags)))
        // A process group id of zero makes a new group whose id is the pid of the child.
        try requireSuccess(posix_spawnattr_setpgroup(&attributes, .zero))
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        try requireSuccess(posix_spawnattr_setsigdefault(&attributes, &allSignals))
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        try requireSuccess(posix_spawnattr_setsigmask(&attributes, &noSignals))
    }

    /// Starts the child with `posix_spawn(2)` and the environment of this process.
    /// - Parameters:
    ///   - executableURL: The executable that the child runs.
    ///   - arguments: The arguments of the executable.
    ///   - fileActions: The file actions of the spawn.
    ///   - attributes: The attributes of the spawn.
    /// - Returns: The pid of the child.
    /// - Throws: A `POSIXError` when the spawn fails.
    private static func launch(
        executableURL: URL,
        arguments: [String],
        fileActions: inout posix_spawn_file_actions_t?,
        attributes: inout posix_spawnattr_t?
    ) throws -> pid_t {
        let path = executableURL.path
        let argumentVector = makeCStringVector([path] + arguments)
        let environmentVector = makeCStringVector(ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" })
        defer {
            freeCStringVector(argumentVector)
            freeCStringVector(environmentVector)
        }
        var pid: pid_t = .zero
        try requireSuccess(posix_spawn(&pid, path, &fileActions, &attributes, argumentVector, environmentVector))
        return pid
    }

    /// Copies `strings` into a `nil`-terminated vector of C strings, the shape of the `argv` and
    /// `envp` arguments of `posix_spawn(2)`. The caller frees the vector with
    /// `freeCStringVector(_:)`.
    /// - Parameter strings: The strings to copy.
    /// - Returns: The copies, and a `nil` at the end.
    private static func makeCStringVector(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { strdup($0) } + [nil]
    }

    /// Frees each C string that `makeCStringVector(_:)` copied.
    /// - Parameter vector: The vector that `makeCStringVector(_:)` made.
    private static func freeCStringVector(_ vector: [UnsafeMutablePointer<CChar>?]) {
        for string in vector {
            free(string)
        }
    }

    /// Closes, in this process, the pipe ends that only the child uses.
    /// - Parameters:
    ///   - standardInput: The null device, or a pipe whose read end belongs to the child.
    ///   - standardOutput: The pipe whose write end belongs to the child.
    ///   - standardError: The pipe whose write end belongs to the child.
    private static func closeChildEnds(
        standardInput: ProcessUtilities.StandardInput,
        standardOutput: Pipe,
        standardError: Pipe
    ) {
        if case .pipe(let pipe) = standardInput {
            try? pipe.fileHandleForReading.close()
        }
        try? standardOutput.fileHandleForWriting.close()
        try? standardError.fileHandleForWriting.close()
    }

    /// Starts the dedicated thread that waits for the exit of the child and reaps it, and then
    /// fires `exitSignal`.
    ///
    /// `waitpid(2)` blocks its thread until the child exits. Thus it runs on a dedicated thread,
    /// not on a thread of the cooperative pool (see
    /// `ProcessUtilities.runOnDedicatedThread(name:_:)`). The thread holds only the pid and the
    /// signal, not the `ProcessGroupChild`.
    /// - Parameters:
    ///   - pid: The pid of the child.
    ///   - exitSignal: The signal to fire after the reap.
    private static func startReaper(pid: pid_t, exitSignal: ExitSignal) {
        _ = ProcessUtilities.runOnDedicatedThread(name: "process-group-reaper \(pid)") {
            var status: Int32 = .zero
            while waitpid(pid, &status, .zero) < .zero, errno == EINTR {
                continue
            }
            exitSignal.fire()
        }
    }
}

/// A signal that fires one time, and that many tasks can wait for.
///
/// A wait returns when the signal fires, or when the task of the wait is cancelled. A wait on an
/// unstructured `Task` does not return at a cancel, thus a race against a timeout (see
/// `ProcessGroupChild.terminateGroup(grace:)`) needs this type.
///
/// A plain `Mutex`-guarded class, not an actor: `fire()` runs on the reaper thread, and the
/// cancel handler of `wait()` runs synchronously, and neither can `await`. Each wait has a token.
/// The cancel handler can run before the wait registers its continuation; then the token goes
/// into `cancelledTokens`, and the registration resumes the continuation at once.
private final class ExitSignal: Sendable {
    /// The state behind the lock.
    private struct State {
        /// Whether `fire()` ran.
        var hasFired = false

        /// The token of the most recent wait.
        var lastToken = 0

        /// The continuation of each wait that did not return yet, by token.
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

        /// The tokens of the waits that were cancelled before they registered.
        var cancelledTokens: Set<Int> = []
    }

    /// The lock and its state.
    private let state = Mutex(State())

    /// Whether the signal fired.
    var hasFired: Bool {
        state.withLock { $0.hasFired }
    }

    /// Fires the signal, and resumes each wait.
    func fire() {
        let waiters = state.withLock { state in
            state.hasFired = true
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Suspends until the signal fires or the task is cancelled. Returns at once when the signal
    /// already fired.
    func wait() async {
        let token = state.withLock { state in
            state.lastToken += 1
            return state.lastToken
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                register(continuation, token: token)
            }
        } onCancel: {
            cancelWait(token: token)
        }
    }

    /// Keeps `continuation` until the signal fires, or resumes it at once when the signal fired
    /// or the wait was cancelled.
    /// - Parameters:
    ///   - continuation: The continuation of the wait.
    ///   - token: The token of the wait.
    private func register(_ continuation: CheckedContinuation<Void, Never>, token: Int) {
        let resumesNow = state.withLock { state in
            let isCancelled = state.cancelledTokens.remove(token) != nil
            if state.hasFired || isCancelled {
                return true
            }
            state.waiters[token] = continuation
            return false
        }
        if resumesNow {
            continuation.resume()
        }
    }

    /// Resumes the wait `token` after a cancel, or records the cancel when the wait did not
    /// register yet.
    /// - Parameter token: The token of the wait.
    private func cancelWait(token: Int) {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { state in
            if let waiter = state.waiters.removeValue(forKey: token) {
                return waiter
            }
            if !state.hasFired {
                state.cancelledTokens.insert(token)
            }
            return nil
        }
        waiter?.resume()
    }
}
