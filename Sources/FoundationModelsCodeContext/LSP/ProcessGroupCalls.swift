import Darwin

/// The process calls of `ProcessGroupChild`: the wait for the exit of the leader of a process
/// group, the reap of the leader, and a signal to the group.
///
/// `SystemProcessGroupCalls` makes the real calls. A unit test gives a fake, which records the
/// order of the reap and the signals without a real process.
protocol ProcessGroupCalls: Sendable {
    /// Blocks until the process `pid` exits, and does not reap it. The process stays as a
    /// zombie, thus its pid, which is also the id of its process group, stays reserved.
    /// - Parameter pid: The pid of a child of this process.
    /// - Returns: The termination status, as `Process.terminationStatus` gives it: the exit
    ///   status when the process exited by itself, or the number of the signal that ended it.
    func waitForExit(of pid: pid_t) -> Int32

    /// Reaps the process `pid`, which exited. Its pid is free after this call.
    /// - Parameter pid: The pid of a child of this process that exited.
    func reap(_ pid: pid_t)

    /// Sends `signal` to each process of the process group `groupID`.
    /// - Parameters:
    ///   - signal: The signal to send, for example `SIGTERM` or `SIGKILL`.
    ///   - groupID: The id of the process group: the pid of its leader.
    func send(_ signal: Int32, toGroup groupID: pid_t)
}

/// The real process calls: `waitid(2)` with `WNOWAIT`, `waitpid(2)` and `kill(2)`.
struct SystemProcessGroupCalls: ProcessGroupCalls {
    func waitForExit(of pid: pid_t) -> Int32 {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < .zero, errno == EINTR {
            continue
        }
        // The wait asks only for an exit (`WEXITED`), thus the code tells one of two things: the
        // process exited by itself (`CLD_EXITED`, and `si_status` is the exit status), or a
        // signal ended it (`CLD_KILLED` or `CLD_DUMPED`, and `si_status` is the number of the
        // signal). Both are the value that `Process.terminationStatus` gives.
        return info.si_status
    }

    func reap(_ pid: pid_t) {
        var status: Int32 = .zero
        while waitpid(pid, &status, .zero) < .zero, errno == EINTR {
            continue
        }
    }

    func send(_ signal: Int32, toGroup groupID: pid_t) {
        _ = kill(-groupID, signal)
    }
}
