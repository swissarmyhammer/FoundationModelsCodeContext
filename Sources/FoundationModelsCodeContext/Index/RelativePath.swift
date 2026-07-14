import Foundation

/// Shared relative-path computation and validation.
///
/// `of(_:relativeTo:)` is used by `Walker` and `GitignoreStack`, which both
/// need to express a filesystem `URL` as a `/`-separated path relative to
/// some base directory (a workspace root or a `.gitignore`'s containing
/// directory). `isSafeRelativePath(_:)` is used by `LSPIndexWorker` and
/// `LiveOpsCore`, which both need to guard a relative path against
/// traversal before resolving it against a workspace root.
enum RelativePath {
    /// Computes `url`'s path relative to `base`, using `/` separators.
    ///
    /// - Parameters:
    ///   - url: The candidate URL.
    ///   - base: The base directory `url` is expected to be nested under.
    /// - Returns: `url`'s path components following `base`'s, joined with
    ///   `/`, or `nil` if `url` is not a descendant of `base`.
    static func of(_ url: URL, relativeTo base: URL) -> String? {
        let baseComponents = base.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count > baseComponents.count,
              Array(urlComponents.prefix(baseComponents.count)) == baseComponents
        else {
            return nil
        }
        return urlComponents.suffix(from: baseComponents.count).joined(separator: "/")
    }

    /// Returns whether `relativePath` is safe to resolve against a
    /// workspace root with `URL.appendingPathComponent(_:)`.
    ///
    /// Rejects an absolute path (leading `/`), a home-relative path
    /// (leading `~`), and any path containing a `..` component — each of
    /// which `appendingPathComponent` would otherwise happily resolve
    /// outside the root. Shared by `LSPIndexWorker` (whose `relativePath`
    /// comes from `indexed_files.file_path`) and `LiveOpsCore` (whose
    /// `filePath` ultimately comes from a public op's caller, an
    /// LSP-index symbol, or a tree-sitter chunk) — neither trusts that
    /// data any more than other externally-sourced input.
    /// - Parameter relativePath: The candidate workspace-relative path.
    /// - Returns: `false` if resolving `relativePath` against a workspace
    ///   root could escape it; `true` otherwise.
    static func isSafeRelativePath(_ relativePath: String) -> Bool {
        guard !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else {
            return false
        }
        return !relativePath.split(separator: "/").contains("..")
    }

    /// Converts a `DocumentURI` back to a workspace-relative path, falling
    /// back to the URI's raw filesystem path when it resolves outside
    /// `rootDirectory` (e.g. a standard-library definition, for a live LSP
    /// response). Shared by `LiveOpsCore` and `DiagnosticsOps`, which both
    /// need to relativize a `DocumentURI` against the workspace root.
    /// - Parameters:
    ///   - uri: The document URI to relativize.
    ///   - rootDirectory: The workspace root `uri` is expected to be nested under.
    /// - Returns: `uri`'s workspace-relative path, or its raw value/filesystem path if it isn't nested under `rootDirectory`.
    static func relativeFilePath(fromURI uri: DocumentURI, rootDirectory: URL) -> String {
        guard let url = URL(string: uri.value) else { return uri.value }
        return of(url, relativeTo: rootDirectory) ?? url.path
    }
}
