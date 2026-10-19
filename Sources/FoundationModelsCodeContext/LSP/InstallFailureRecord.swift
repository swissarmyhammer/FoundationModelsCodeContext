import Foundation
import Logging

/// The per-user record of failed language server installs: one JSON file that each session of
/// each workspace on the machine reads and writes.
///
/// The in-memory dedupe of `ServerInstaller` lasts one session. A new session (a new
/// `CodeContext`, often for a new clone of a repository) starts with no memory of an install
/// that failed a minute ago in another session, and runs the same failing installer again. The
/// record lives in a directory of the user, not in the `.code-context/` directory of a
/// workspace, so a failure in one workspace is known in all of them.
///
/// The record never fails an install. A file that cannot be read, cannot be decoded or cannot
/// be written is logged at warning, and the install goes on as if the record were empty.
/// Each write goes to a temporary file that then replaces the record (`Data.write(to:options:)`
/// with `.atomic`), so a reader never sees a half-written file. Two sessions that write at the
/// same time can lose one update; the cost is one more run of an installer.
struct InstallFailureRecord: Sendable {
    /// What one entry of the record is about: one installer command of one language server.
    /// A changed installer command (other arguments, another version) is another key, so a
    /// changed install spec is tried again at once.
    struct Key: Codable, Hashable, Sendable {
        /// The command of the language server, `ServerSpec.command`.
        let command: String

        /// The installer executable, `ServerSpec.InstallSpec.tool`.
        let tool: String

        /// The installer arguments, `ServerSpec.InstallSpec.arguments`.
        let arguments: [String]
    }

    /// One failed install.
    struct Entry: Codable, Equatable, Sendable {
        /// The installer command that failed.
        let key: Key

        /// When the install failed.
        let failedAt: Date

        /// The exit code of the installer, or `nil` when the run did not complete (a timeout or
        /// a failed spawn).
        let exitCode: Int32?

        /// The error code that `InstallFailureReason.code(in:)` took out of the installer
        /// output, or `nil` when the output held none.
        let reason: String?
    }

    /// The name of the record file in its directory.
    static let fileName = "install-failures.json"

    /// The record file.
    let fileURL: URL

    /// Creates the record that lives in `directory`. Reads and writes nothing yet.
    /// - Parameter directory: The directory of the record file. A write creates it.
    init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// Gives the recorded failure of `key`.
    /// - Parameter key: The installer command.
    /// - Returns: The entry of `key`, or `nil` when the record holds none or cannot be read.
    func entry(for key: Key) -> Entry? {
        readEntries().first { $0.key == key }
    }

    /// Records `entry`, in place of an earlier entry of the same key.
    /// - Parameter entry: The failure to record.
    func store(_ entry: Entry) {
        write(readEntries().filter { $0.key != entry.key } + [entry])
    }

    /// Removes the entry of `key`. Writes nothing when the record holds no entry of `key`.
    /// - Parameter key: The installer command that succeeded.
    func removeEntry(for key: Key) {
        let entries = readEntries()
        guard entries.contains(where: { $0.key == key }) else { return }
        write(entries.filter { $0.key != key })
    }

    /// Reads every entry of the record file.
    /// - Returns: The entries, or none when the file does not exist, cannot be read or cannot be
    ///   decoded. Only a missing file is not logged.
    private func readEntries() -> [Entry] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if (error as? CocoaError)?.code != .fileReadNoSuchFile {
                Self.logFailure("the record of failed language server installs could not be read", error: error)
            }
            return []
        }
        do {
            return try Self.makeDecoder().decode([Entry].self, from: data)
        } catch {
            Self.logFailure("the record of failed language server installs could not be decoded", error: error)
            return []
        }
    }

    /// Replaces the record file with `entries`, through a temporary file.
    /// - Parameter entries: Every entry the record holds after the write.
    private func write(_ entries: [Entry]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.makeEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            Self.logFailure("the record of failed language server installs could not be written", error: error)
        }
    }

    /// Logs a read or write failure of the record at warning, with the type of the error only.
    /// - Parameters:
    ///   - message: The fixed message of the record.
    ///   - error: The failure. The record holds its type name, never its description.
    private static func logFailure(_ message: Logger.Message, error: any Error) {
        Log.lsp.warning(message, metadata: Log.errorDetail(of: error))
    }

    /// Gives the decoder of the record file: dates in ISO 8601.
    /// - Returns: The decoder.
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Gives the encoder of the record file: dates in ISO 8601, sorted keys, for a file a person
    /// can read.
    /// - Returns: The encoder.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// The backoff policy over an `InstallFailureRecord`: an installer command that failed less
/// than `window` ago is not run again.
struct InstallFailureBackoff: Sendable {
    /// The number of attoseconds in one second, for the conversion of a `Duration`.
    private static let attosecondsPerSecond = 1e18

    /// The record of failed installs.
    let record: InstallFailureRecord

    /// How long after a failure the same installer command is not run again.
    let window: Duration

    /// Gives the current time. Tests give a fixed time.
    let now: @Sendable () -> Date

    /// Gives the recorded failure of `key` when it is younger than `window`.
    /// - Parameter key: The installer command.
    /// - Returns: The failure that blocks a new run, or `nil` when the installer may run.
    func activeFailure(for key: InstallFailureRecord.Key) -> InstallFailureRecord.Entry? {
        guard let failure = record.entry(for: key), now() < retryTime(after: failure) else { return nil }
        return failure
    }

    /// Gives the time from which the installer command of `failure` may run again.
    /// - Parameter failure: A recorded failure.
    /// - Returns: The failure time plus `window`.
    func retryTime(after failure: InstallFailureRecord.Entry) -> Date {
        let components = window.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / Self.attosecondsPerSecond
        return failure.failedAt.addingTimeInterval(seconds)
    }

    /// Records a failed run of the installer command `key`, at the current time.
    /// - Parameters:
    ///   - key: The installer command.
    ///   - exitCode: The exit code, or `nil` when the run did not complete.
    ///   - reason: The error code of the installer output, or `nil`.
    func noteFailure(of key: InstallFailureRecord.Key, exitCode: Int32?, reason: String?) {
        record.store(InstallFailureRecord.Entry(key: key, failedAt: now(), exitCode: exitCode, reason: reason))
    }

    /// Clears the recorded failure of the installer command `key`, which succeeded.
    /// - Parameter key: The installer command.
    func noteSuccess(of key: InstallFailureRecord.Key) {
        record.removeEntry(for: key)
    }
}
