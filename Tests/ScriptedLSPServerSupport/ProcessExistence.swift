import Foundation

/// Tells if a process with the id `pid` exists, from `kill(pid, 0)`. Signal `0` sends no signal:
/// the call only checks the id. A zombie process that its parent did not reap yet still exists.
///
/// The unit test target of the root package and the test target of the integration package both
/// use this function. Thus the check has one body.
/// - Parameter pid: The process id to check.
/// - Returns: `true` when the call finds the process (`0`, or `EPERM` for a process of another
///   user); `false` when it reports `ESRCH`.
public func processExists(_ pid: pid_t) -> Bool {
    errno = 0
    return kill(pid, 0) == 0 || errno != ESRCH
}
