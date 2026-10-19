import Darwin
import Foundation

/// Reads the process table of the kernel: the processes of one process group,
/// and the arguments of one process.
///
/// A language server that Code Context starts leads its own process group (see
/// `ProcessGroupChild`), thus the id of the group is the pid of the server, and
/// each process in that group belongs to that server. The tests use the group to
/// attribute a process to the server, also after the death of the server
/// reparents the process to `launchd`. A raw count of the processes of a name
/// would mix in the processes of other hosts on the machine, for example the
/// `pylsp` that `sah serve` starts.
internal enum ProcessTable {
    /// The number of extra slots that `members(ofGroup:)` adds to the buffer,
    /// for processes that the group starts between the two calls of
    /// `proc_listpids(3)`.
    private static let extraGroupSlots = 16

    /// Gives the id of each process in the process group `groupID`. A zombie
    /// process that its parent did not reap yet is a member too.
    /// - Parameter groupID: The id of the process group.
    /// - Returns: The ids of the processes of the group; empty when the group
    ///   has no process.
    internal static func members(ofGroup groupID: pid_t) -> [pid_t] {
        let filter = UInt32(PROC_PGRP_ONLY)
        let byteCount = proc_listpids(filter, UInt32(groupID), nil, .zero)
        guard byteCount > .zero else {
            return []
        }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.stride + extraGroupSlots
        var pids = [pid_t](repeating: .zero, count: capacity)
        let filledByteCount = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(filter, UInt32(groupID), buffer.baseAddress, Int32(buffer.count))
        }
        let filledCount = max(Int(filledByteCount), .zero) / MemoryLayout<pid_t>.stride
        return pids.prefix(filledCount).filter { $0 != .zero }
    }

    /// Gives the process group id of the process `pid`.
    /// - Parameter pid: The id of the process.
    /// - Returns: The id of the group, or `nil` when no process has the id.
    internal static func groupID(of pid: pid_t) -> pid_t? {
        let groupID = getpgid(pid)
        return groupID < .zero ? nil : groupID
    }

    /// Gives the arguments of the process `pid`, from the `KERN_PROCARGS2`
    /// sysctl: the argument count, the executable path, and then the
    /// arguments, each one ended by a zero byte.
    /// - Parameter pid: The id of the process.
    /// - Returns: The arguments, the first one being the program name; empty
    ///   when the kernel gives no arguments, for example for a process that
    ///   exited.
    internal static func arguments(of pid: pid_t) -> [String] {
        var managementInformationBase: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = Int.zero
        guard sysctl(&managementInformationBase, UInt32(managementInformationBase.count), nil, &length, nil, .zero) == .zero else {
            return []
        }
        var buffer = [UInt8](repeating: .zero, count: length)
        guard sysctl(&managementInformationBase, UInt32(managementInformationBase.count), &buffer, &length, nil, .zero) == .zero else {
            return []
        }
        return parsedArguments(in: buffer.prefix(length))
    }

    /// Reads the arguments out of a `KERN_PROCARGS2` buffer.
    /// - Parameter buffer: The bytes that the sysctl wrote.
    /// - Returns: The arguments; empty when the buffer is too short.
    private static func parsedArguments(in buffer: ArraySlice<UInt8>) -> [String] {
        let countSize = MemoryLayout<Int32>.size
        guard buffer.count >= countSize else {
            return []
        }
        let argumentCount = buffer.prefix(countSize).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        // The executable path follows the count, and zero bytes pad it before the first argument.
        let fields = buffer.dropFirst(countSize).split(separator: .zero, omittingEmptySubsequences: true)
        return fields.dropFirst().prefix(Int(argumentCount)).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Counts the Jedi subprocesses of one `pylsp`.
///
/// Jedi starts its compiled-module subprocess with a plain `subprocess.Popen`,
/// thus the subprocess is in the process group of `pylsp`. The count reads only
/// that group, thus the Jedi subprocesses of a `pylsp` that another host
/// started (for example `sah serve`) are not in it.
internal enum JediProcesses {
    /// The end of the script path that each Jedi subprocess runs.
    private static let scriptPathSuffix = "jedi/inference/compiled/subprocess/__main__.py"

    /// Counts the Jedi subprocesses in the process group of `pylsp`.
    /// - Parameter pylspPID: The pid of a `pylsp` that leads its own process
    ///   group.
    /// - Returns: The number of members of the group that run the Jedi
    ///   subprocess script.
    internal static func count(inGroupOf pylspPID: pid_t) -> Int {
        ProcessTable.members(ofGroup: pylspPID)
            .filter { pid in ProcessTable.arguments(of: pid).contains { $0.hasSuffix(scriptPathSuffix) } }
            .count
    }
}
