import Foundation
import Logging

/// The read of the disk text of a source file, for the index workers.
///
/// A read can give no text for three reasons, and each worker logs each one
/// at its own level:
/// - No file is at the path. An agent often writes a scratch file and
///   deletes it again before the worker reads it. This is not an error.
/// - The file holds bytes that are not UTF-8 text. This is a fact of the
///   workspace, not an error.
/// - The read fails for another reason, for example a permission error or
///   an I/O error. This is a warning.
enum SourceText {
    /// Why a read gives no text.
    enum ReadFailure: Error {
        /// No file is at the path.
        case missing

        /// The file holds bytes that are not UTF-8 text.
        case notUTF8

        /// The read failed for another reason. The value names the type of
        /// the error (see `Log.errorType(of:)`), and never holds the
        /// description of the error, because a description can hold content.
        case unreadable(errorType: Logger.MetadataValue)
    }

    /// Reads the file at `fileURL` as UTF-8 text.
    ///
    /// The read does not check the path. The caller checks it first, for
    /// example with `RelativePath.isSafeRelativePath(_:)`.
    /// - Parameter fileURL: The file to read.
    /// - Returns: The text of the file.
    /// - Throws: `ReadFailure` when the read gives no text.
    static func read(at fileURL: URL) throws(ReadFailure) -> String {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw failure(of: error)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw .notUTF8
        }
        return text
    }

    /// Gives the failure that a read error of `Data(contentsOf:)` stands for.
    /// - Parameter error: The error of the read.
    /// - Returns: `.missing` when no file is at the path, else `.unreadable`
    ///   with the type name of `error`.
    private static func failure(of error: any Error) -> ReadFailure {
        guard isMissingFile(error) else {
            return .unreadable(errorType: Log.errorType(of: error))
        }
        return .missing
    }

    /// Tells if a read error of `Data(contentsOf:)` says that no file is at
    /// the path.
    ///
    /// The watcher reads the bytes of a file with `Walker.hashFile`, not its
    /// text, and asks this function for the same split as `read(at:)`.
    /// - Parameter error: The error of the read.
    /// - Returns: `true` when no file is at the path.
    static func isMissingFile(_ error: any Error) -> Bool {
        (error as? CocoaError)?.code == .fileReadNoSuchFile
    }
}
