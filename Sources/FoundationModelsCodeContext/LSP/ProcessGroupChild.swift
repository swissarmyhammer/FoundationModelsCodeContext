import Darwin
import Foundation

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
/// A dedicated thread waits for the exit of the child with `waitid(2)` and `WNOWAIT`, which does
/// not reap it. `isRunning` is `false` from the time of the exit, and `terminationStatus` then
/// gives the status of the exit.
///
/// The pid of the child is also the id of its group, thus the reap waits until no group signal
/// can come. After the reap the kernel can give that pid to a new process, and when that process
/// leads a group of its own (each language server does, and SwiftPM starts each test binary in a
/// new group), a signal to `-pid` reaches that unrelated group. While the child is a zombie its
/// pid stays reserved, so no other process can get it or lead a group with that id. The child is
/// reaped after `terminateGroup(grace:)` sent `SIGKILL`, or at the release of this object,
/// whichever comes first. A group signal after the reap sends nothing.
final class ProcessGroupChild: Sendable {
    /// The state of the child, the leader of its process group.
    private enum LeaderState: Equatable, Sendable {
        /// The child did not exit yet. `isReapAllowed` is `true` when no group signal can come,
        /// thus the reaper thread reaps the child at its exit.
        case running(isReapAllowed: Bool)

        /// The child exited and stays as a zombie, which keeps its pid reserved.
        case exited

        /// The child exited and was reaped. Its pid is free, thus no group signal goes out.
        case reaped
    }

    /// The pid of the child. The child leads its process group, thus this is also the id of the
    /// group.
    let pid: pid_t

    /// The process calls: the wait for the exit, the reap and the group signal.
    private let calls: any ProcessGroupCalls

    /// The state of the child, and the waits for its exit. Each group signal and the reap run
    /// while its lock is held, thus no signal can come after the reap.
    private let leader: CancellableWaiters<LeaderState>

    /// The reaper thread. Its value is the termination status of the child.
    private let reaper: Task<Int32, Never>

    /// Keeps the pid of a started child, and starts the thread that waits for its exit.
    /// - Parameters:
    ///   - pid: The pid of the child, the leader of its own process group.
    ///   - calls: The process calls. `spawn` gives `SystemProcessGroupCalls`.
    init(pid: pid_t, calls: any ProcessGroupCalls) {
        self.pid = pid
        self.calls = calls
        let leader = CancellableWaiters(LeaderState.running(isReapAllowed: false)) { state in
            Self.hasExited(state)
        }
        self.leader = leader
        self.reaper = Self.startReaper(pid: pid, leader: leader, calls: calls)
    }

    /// Allows the reap of the child at its release: no caller can send a group signal after it.
    deinit {
        allowReap()
    }

    /// Starts `executableURL` as the leader of a new process group, and starts the thread that
    /// waits for its exit.
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
        return ProcessGroupChild(pid: pid, calls: SystemProcessGroupCalls())
    }

    /// Whether the child did not exit yet. The value is `false` from the time that the reaper
    /// thread sees the exit of the child.
    var isRunning: Bool {
        leader.read { state in !Self.hasExited(state) }
    }

    /// Sends `signal` to each process of the process group of the child.
    ///
    /// The group stays while one of its processes stays, also after the exit of the child. When
    /// no process of the group stays, the call does nothing. After the reap of the child the
    /// call sends nothing, because its pid can then lead an unrelated group.
    /// - Parameter signal: The signal to send, for example `SIGTERM` or `SIGKILL`.
    func signalGroup(_ signal: Int32) {
        leader.update { state in
            guard state != .reaped else { return }
            calls.send(signal, toGroup: pid)
        }
    }

    /// Suspends until the reaper thread sees the exit of the child, or until the task of the
    /// caller is cancelled. Returns at once when the child already exited.
    func waitUntilExit() async {
        await leader.wait()
    }

    /// The termination status of the child, as `Process.terminationStatus` gives it: the exit
    /// status when the child exited by itself, or the number of the signal that ended it.
    ///
    /// Suspends until the reaper thread sees the exit of the child. A cancel of the task of the
    /// caller does not end this wait, thus read it after the child exited or after
    /// `terminateGroup(grace:)` sent `SIGKILL`, never as a race against a time limit.
    var terminationStatus: Int32 {
        get async { await reaper.value }
    }

    /// Stops each process of the process group, and waits for the reap of the child.
    ///
    /// Sends `SIGTERM` to the group, and waits at most `grace` for the exit of the child. Then
    /// sends `SIGKILL` to the group, also when the child exited in time: a process of the group
    /// that ignores `SIGTERM`, or that the exit of the child did not stop, must also stop. Then
    /// reaps the child, at once when it already exited or else at its exit, and waits for that
    /// reap. A group signal after this call sends nothing.
    /// - Parameter grace: The time that the child gets to exit after `SIGTERM`.
    func terminateGroup(grace: Duration) async {
        signalGroup(SIGTERM)
        let leader = self.leader
        await ContinuousClock().waitForCompletion(atMost: grace) { await leader.wait() }
        signalGroup(SIGKILL)
        allowReap()
        await waitUntilExit()
    }

    /// Allows the reap of the child, because no group signal comes after this call.
    ///
    /// Reaps a child that exited at once. The reaper thread reaps a child that did not exit yet
    /// at its exit. Does nothing after the reap.
    private func allowReap() {
        leader.update { state in
            switch state {
            case .running:
                state = .running(isReapAllowed: true)
            case .exited:
                calls.reap(pid)
                state = .reaped
            case .reaped:
                break
            }
        }
    }

    /// Whether `state` is after the exit of the child.
    /// - Parameter state: A state of the child.
    /// - Returns: `false` while the child runs; `true` after its exit, also after its reap.
    private static func hasExited(_ state: LeaderState) -> Bool {
        guard case .running = state else { return true }
        return false
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

    /// Starts the dedicated thread that waits for the exit of the child, and then records the
    /// exit in `leader`, which resumes each wait for the exit.
    ///
    /// The thread reaps the child at its exit only when the reap is allowed already (see
    /// `allowReap()`). Otherwise the child stays as a zombie, and `allowReap()` reaps it later.
    ///
    /// The wait blocks its thread until the child exits. Thus it runs on a dedicated thread, not
    /// on a thread of the cooperative pool (see `ProcessUtilities.runOnDedicatedThread(name:_:)`).
    /// The thread holds only the pid, the state and the process calls, not the
    /// `ProcessGroupChild`.
    /// - Parameters:
    ///   - pid: The pid of the child.
    ///   - leader: The state of the child.
    ///   - calls: The process calls.
    /// - Returns: The task of the thread. Its value is the termination status of the child.
    private static func startReaper(
        pid: pid_t,
        leader: CancellableWaiters<LeaderState>,
        calls: any ProcessGroupCalls
    ) -> Task<Int32, Never> {
        ProcessUtilities.runOnDedicatedThread(name: "process-group-reaper \(pid)") {
            let status = calls.waitForExit(of: pid)
            leader.update { state in
                guard state == .running(isReapAllowed: true) else {
                    state = .exited
                    return
                }
                calls.reap(pid)
                state = .reaped
            }
            return status
        }
    }
}
