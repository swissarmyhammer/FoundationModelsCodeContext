import Foundation

/// Discovers git-repository roots under a parent directory, and resolves
/// the enclosing repo root for an arbitrary path.
///
/// Stateless namespace mirroring `ProjectDetection`, but git-repo-scoped:
/// "git repo = the project unit" is the agreed intent here, so — unlike
/// `ProjectDetection` — there is no project-marker fallback. A directory
/// without a `.git` entry is never a discovered root, regardless of what
/// language markers it contains. A caller that wants a non-git directory
/// as a workspace opens it explicitly via `CodeContext`, which accepts any
/// directory; this keeps discovery symmetric with lazy routing via
/// `gitRoot(containing:)` and avoids a marker directory shadowing a git
/// repo nested beneath it.
public enum RootDiscovery {
    /// Resource keys needed to distinguish directories, symbolic links, and
    /// regular files while traversing — shared by both the directory listing
    /// and the per-child resource-value lookup so the two stay in sync.
    private static let traversalResourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]

    /// Finds every git-repository root under `parent`.
    ///
    /// Uses its own `FileManager` traversal rather than
    /// `Walker.walkEntries(rootDirectory:)`: `Walker` skips hidden entries,
    /// so it can never observe a `.git` entry. A directory containing a
    /// `.git` entry — directory (normal repo) or file (worktree/submodule)
    /// — is a root, and traversal is pruned below it, so a repo nested
    /// inside another repo's working tree is never returned (the git-repo
    /// unit is the outermost `.git` boundary on each branch of the tree).
    /// Hidden directories are not descended into and symbolic links are not
    /// followed, mirroring `Walker`'s policy — except the `.git` presence
    /// check itself, which runs on every visited directory regardless of
    /// that directory's own hidden status.
    ///
    /// - Parameter parent: The directory to search beneath.
    /// - Returns: Every discovered repo root, standardized and sorted by
    ///   path.
    /// - Throws: Rethrows `FileManager`'s directory-enumeration errors.
    public static func discoverRoots(under parent: URL) throws -> [URL] {
        var roots: [URL] = []
        try collectRoots(in: parent.standardizedFileURL, into: &roots)
        return roots.sorted { $0.path < $1.path }
    }

    /// Walks upward from `path` to the nearest ancestor directory
    /// containing a `.git` entry.
    ///
    /// - Parameter path: The file or directory to resolve an enclosing repo
    ///   root for. When `path` is a file (or does not exist), the search
    ///   starts at its containing directory.
    /// - Returns: The standardized enclosing repo root, or `nil` if no
    ///   ancestor up to the filesystem root contains a `.git` entry.
    public static func gitRoot(containing path: URL) -> URL? {
        let standardizedPath = path.standardizedFileURL
        let isDirectory = (try? standardizedPath.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        var current = isDirectory ? standardizedPath : standardizedPath.deletingLastPathComponent()

        // Walk upward until `current` is the filesystem root (a single "/"
        // path component). `URL.deletingLastPathComponent()` does not
        // reliably fix at the root — calling it again on "/" can yield
        // "/.." rather than "/" itself — so termination is decided by
        // `pathComponents.count` on the current directory instead of by
        // comparing `current` against its own computed parent.
        while true {
            if containsGitEntry(current) {
                return current.standardizedFileURL
            }
            guard current.pathComponents.count > 1 else {
                return nil
            }
            current = current.deletingLastPathComponent()
        }
    }

    /// Recursively finds git-repo roots under `directory`, appending each
    /// to `roots` and pruning traversal below it.
    ///
    /// - Parameters:
    ///   - directory: The directory to check and, if it is not itself a
    ///     root, descend into.
    ///   - roots: Accumulates discovered roots across the recursion.
    /// - Throws: Rethrows `FileManager`'s directory-enumeration and
    ///   resource-value errors.
    private static func collectRoots(in directory: URL, into roots: inout [URL]) throws {
        if containsGitEntry(directory) {
            roots.append(directory.standardizedFileURL)
            return
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(traversalResourceKeys),
            options: []
        )
        for child in children where !child.lastPathComponent.hasPrefix(".") {
            let resourceValues = try child.resourceValues(forKeys: traversalResourceKeys)
            guard resourceValues.isSymbolicLink != true, resourceValues.isDirectory == true else {
                continue
            }
            try collectRoots(in: child, into: &roots)
        }
    }

    /// `true` if `directory` has a direct `.git` entry, whether a
    /// directory (normal repo) or a file (worktree/submodule pointer).
    ///
    /// - Parameter directory: The directory to check.
    private static func containsGitEntry(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path)
    }
}
