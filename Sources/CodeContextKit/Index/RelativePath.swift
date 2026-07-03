import Foundation

/// Shared relative-path computation used by `Walker` and `GitignoreStack`,
/// which both need to express a filesystem `URL` as a `/`-separated path
/// relative to some base directory (a workspace root or a `.gitignore`'s
/// containing directory).
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
}
