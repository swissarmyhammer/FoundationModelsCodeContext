import Foundation

/// A workspace root, with its canonical form.
///
/// `relativePath(of:)` is the one function that makes the row key of a file:
/// the watcher, the reconcile walk (through `PathFilter`), `QueryAST` (through
/// the walk) and `DiagnosticsScopeResolver` use it. The LSP index worker, the
/// live operations and the diagnostics operation use it for each URI that a
/// language server sends (`relativePath(ofURI:)` and
/// `relativeFilePath(fromURI:)`). If two of them made different keys for
/// one file, the file would get two rows in `indexed_files`, and the reconcile
/// and the watcher would delete and add the second row again and again.
///
/// The canonical root is the real path of the root from `realpath(3)`.
/// FSEvents sends real paths: for a root of `/var/folders/...` it sends
/// `/private/var/folders/...`, and for a root that is a symbolic link it
/// sends the path of the target. `URL.resolvingSymlinksInPath()` is not
/// sufficient, because it removes the `/private` prefix again.
struct WorkspaceRoot: Sendable, Equatable {
    /// The root URL as the caller gave it.
    let url: URL

    /// The path components of the standardized root URL.
    let components: [String]

    /// The real path of the root. It is the same as `url` when the root has no
    /// symbolic link in its path.
    let canonicalURL: URL

    /// The path components of the real path of the root. They are the same as
    /// `components` when the root has no symbolic link in its path.
    let canonicalComponents: [String]

    /// Makes the root and computes its canonical form.
    ///
    /// The canonical form comes from `realpath(3)`. When `realpath(3)` fails
    /// (for example, the root does not exist yet), it comes from
    /// `URL.resolvingSymlinksInPath()`.
    /// - Parameter url: The workspace root.
    init(_ url: URL) {
        self.url = url
        components = RelativePath.components(of: url)
        canonicalURL = Self.canonicalURL(of: url)
        canonicalComponents = RelativePath.components(of: canonicalURL)
    }

    /// Gives the path of `url` relative to the root, with `/` separators.
    ///
    /// The function removes the root from the path. If the path does not start
    /// with the root, it removes the canonical root.
    /// - Parameter url: A file URL.
    /// - Returns: The relative path, or `nil` when `url` is the root itself or
    ///   is not below the root or the canonical root.
    func relativePath(of url: URL) -> String? {
        relativeComponents(of: url)?.joined(separator: "/")
    }

    /// Gives the path of the file of `uri` relative to the root, with `/`
    /// separators. See `relativePath(of:)`.
    ///
    /// A language server can send the real path of a file: for a root of
    /// `/var/folders/...` it sends `/private/var/folders/...`, and for a root
    /// that is a symbolic link it sends the path of the target. The canonical
    /// root gives the relative path also for such a URI.
    /// - Parameter uri: A document URI from a language server.
    /// - Returns: The relative path, or `nil` when `uri` is not a URL, or its
    ///   file is not below the root or the canonical root (for example a
    ///   library outside the workspace).
    func relativePath(ofURI uri: DocumentURI) -> String? {
        Self.url(of: uri).flatMap(relativePath(of:))
    }

    /// Gives the path of the file of `uri` relative to the root, or a path
    /// that shows the file when it is not below the root.
    ///
    /// A live operation shows each location that a language server gives,
    /// also a location outside the workspace (for example a standard-library
    /// definition). Thus this function does not give `nil`.
    /// - Parameter uri: A document URI from a language server.
    /// - Returns: The relative path (see `relativePath(of:)`). When the file is
    ///   not below the root or the canonical root, the absolute file path. When
    ///   `uri` is not a URL, the raw value of `uri`.
    func relativeFilePath(fromURI uri: DocumentURI) -> String {
        guard let url = Self.url(of: uri) else {
            return uri.value
        }
        return relativePath(of: url) ?? url.path
    }

    /// Gives the URL of `uri`. `relativePath(ofURI:)` and
    /// `relativeFilePath(fromURI:)` use this one parse, thus they cannot make
    /// different URLs from one URI.
    /// - Parameter uri: A document URI from a language server.
    /// - Returns: The URL, or `nil` when `uri` is not a URL.
    private static func url(of uri: DocumentURI) -> URL? {
        URL(string: uri.value)
    }

    /// Gives the path components of `url` relative to the root.
    ///
    /// The function removes the root from the path. If the path does not start
    /// with the root, it removes the canonical root.
    /// - Parameter url: A file URL.
    /// - Returns: The relative components (never empty), or `nil` when `url` is
    ///   the root itself or is not below the root or the canonical root.
    func relativeComponents(of url: URL) -> [String]? {
        relativeComponents(ofPathComponents: RelativePath.components(of: url))
    }

    /// Gives the path components relative to the root, from the path
    /// components of a standardized URL that the caller computed before.
    ///
    /// The walk calls this form for each entry: it builds the components of a
    /// child from the components of its directory, thus it makes no
    /// standardized URL for each entry.
    /// - Parameter pathComponents: The path components of a standardized URL,
    ///   as `RelativePath.components(of:)` gives them.
    /// - Returns: The components after the root, else the components after the
    ///   canonical root, or `nil` when the path is the root itself or is not
    ///   below the root or the canonical root.
    func relativeComponents(ofPathComponents pathComponents: [String]) -> [String]? {
        RelativePath.components(pathComponents, after: components)
            ?? RelativePath.components(pathComponents, after: canonicalComponents)
    }

    /// Gives the real path of `url` from `realpath(3)`, or the result of
    /// `URL.resolvingSymlinksInPath()` when `realpath(3)` fails.
    /// - Parameter url: A file URL.
    /// - Returns: The real path as a file URL.
    private static func canonicalURL(of url: URL) -> URL {
        realURL(of: url) ?? url.resolvingSymlinksInPath()
    }

    /// Gives the real path of `url` from `realpath(3)`: each symbolic link is
    /// resolved, and the `/private` prefix of `/var` and `/tmp` stays.
    /// - Parameter url: A file URL.
    /// - Returns: The real path as a file URL, or `nil` when `realpath(3)`
    ///   fails (for example, the item does not exist).
    static func realURL(of url: URL) -> URL? {
        let resolvedPath = url.standardizedFileURL.path.withCString { pointer -> String? in
            guard let buffer = realpath(pointer, nil) else {
                return nil
            }
            defer { free(buffer) }
            return String(cString: buffer)
        }
        return resolvedPath.map { URL(fileURLWithPath: $0) }
    }
}

/// Shared relative-path computation and validation.
///
/// `WorkspaceRoot` uses the component functions to make the row key of a
/// file. `isSafeRelativePath(_:)` is used by `LSPIndexWorker` and
/// `LiveOpsCore`, which both need to guard a relative path against traversal
/// before resolving it against a workspace root.
enum RelativePath {
    /// Gives the path components that follow a base directory, from path
    /// components that the caller computed before.
    ///
    /// - Parameters:
    ///   - urlComponents: The path components of the candidate URL, from
    ///     `components(of:)`.
    ///   - baseComponents: The path components of the base directory, from
    ///     `components(of:)`.
    /// - Returns: The components that follow `baseComponents` (never empty),
    ///   or `nil` if the candidate is not a descendant of the base.
    static func components(_ urlComponents: [String], after baseComponents: [String]) -> [String]? {
        guard urlComponents.count > baseComponents.count,
            urlComponents.starts(with: baseComponents)
        else {
            return nil
        }
        return Array(urlComponents.suffix(from: baseComponents.count))
    }

    /// The path components of the standardized form of `url`, the input of
    /// `components(_:after:)`.
    ///
    /// - Parameter url: A file URL.
    /// - Returns: The path components of `url.standardizedFileURL`.
    static func components(of url: URL) -> [String] {
        url.standardizedFileURL.pathComponents
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
}
