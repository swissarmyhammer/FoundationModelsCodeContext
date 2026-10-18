import Foundation

/// A document that a language server may open: the path filter accepts its
/// path. The value holds the path and the document URI.
///
/// The LSP index worker, the references fallback, the live operations and the
/// diagnostics operation make this value before they sync a document. Thus they
/// all use one path check, one URI form and one disk read. The value does not
/// read the file: each caller calls `readText()` where it syncs the document.
/// The work that comes after (the sync, the use and the close) stays at each
/// caller.
struct LanguageServerDocument: Sendable {
    /// The path of the document relative to `rootDirectory`.
    let relativePath: String

    /// The workspace root.
    let rootDirectory: URL

    /// The URI of the document below the workspace root.
    let uri: DocumentURI

    /// Makes the document at `relativePath` when `pathFilter` accepts it (see
    /// `PathFilter.acceptsDocument(relativePath:)`). The init does not read
    /// the file; call `readText()` for the disk text.
    /// - Parameters:
    ///   - relativePath: The path of the document relative to `rootDirectory`.
    ///   - rootDirectory: The workspace root.
    ///   - pathFilter: The path filter that must accept the path.
    /// - Returns: `nil` when `pathFilter` does not accept the path.
    init?(relativePath: String, rootDirectory: URL, pathFilter: PathFilter) {
        guard pathFilter.acceptsDocument(relativePath: relativePath) else {
            return nil
        }
        self.relativePath = relativePath
        self.rootDirectory = rootDirectory
        uri = Self.uri(relativePath: relativePath, rootDirectory: rootDirectory)
    }

    /// Reads the disk text of the document now. Each call reads the file
    /// again (see `readText(relativePath:rootDirectory:)`).
    /// - Returns: The text, or `nil` when the file cannot be read or is not
    ///   UTF-8 text.
    func readText() -> String? {
        Self.readText(relativePath: relativePath, rootDirectory: rootDirectory)
    }

    /// Builds the document URI of `relativePath` below `rootDirectory`. The
    /// build does not read the disk.
    /// - Parameters:
    ///   - relativePath: The path of the document relative to `rootDirectory`.
    ///   - rootDirectory: The workspace root.
    /// - Returns: The document URI.
    static func uri(relativePath: String, rootDirectory: URL) -> DocumentURI {
        DocumentURI(rootDirectory.appendingPathComponent(relativePath).absoluteString)
    }

    /// Reads the disk text of `relativePath` as UTF-8.
    ///
    /// The read rejects a path that `RelativePath.isSafeRelativePath(_:)` does
    /// not accept before it touches the disk, thus a `..` component or an
    /// absolute path never reads a file out of the root.
    /// - Parameters:
    ///   - relativePath: The path of the file relative to `rootDirectory`.
    ///   - rootDirectory: The workspace root.
    /// - Returns: The text, or `nil` when the path is not safe, or the file
    ///   cannot be read or is not UTF-8 text.
    static func readText(relativePath: String, rootDirectory: URL) -> String? {
        guard RelativePath.isSafeRelativePath(relativePath) else {
            return nil
        }
        let fileURL = rootDirectory.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

extension SharedPathFilter {
    /// Makes the document at `relativePath` with the current filter, when the
    /// filter accepts it. See
    /// `LanguageServerDocument.init(relativePath:rootDirectory:pathFilter:)`.
    ///
    /// The check reads `realpath(3)`, thus it runs off this actor. The
    /// document does not read the file; the caller calls `readText()`.
    /// - Parameters:
    ///   - relativePath: The path of the document relative to `rootDirectory`.
    ///   - rootDirectory: The workspace root.
    /// - Returns: The document, or `nil` when the filter does not accept the
    ///   path.
    nonisolated func acceptedDocument(relativePath: String, rootDirectory: URL) async -> LanguageServerDocument? {
        LanguageServerDocument(relativePath: relativePath, rootDirectory: rootDirectory, pathFilter: await filter)
    }
}
