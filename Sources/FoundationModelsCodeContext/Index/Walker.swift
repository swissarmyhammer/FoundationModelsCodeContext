import CryptoKit
import Foundation

/// One indexable file discovered under a workspace root, with its
/// workspace-relative path and truncated content hash ready for
/// `Reconciler` to compare against `indexed_files`.
///
/// Port of `cleanup.rs`'s private `HashedFile`.
struct HashedFile: Sendable, Equatable {
    /// Path relative to the workspace root, using `/` separators — the
    /// same string `Reconciler` stores in `indexed_files.file_path`.
    let relativePath: String

    /// The first 16 bytes of the file's SHA-256 digest.
    let contentHash: Data

    /// The file size in bytes, as read from disk.
    let fileSize: Int64
}

/// Gitignore-aware filesystem walker used to discover and hash indexable
/// files under a workspace root.
///
/// Port of `cleanup.rs::walk_and_hash`, replicating the subset of
/// `ignore::WalkBuilder`'s defaults FoundationModelsCodeContext needs: `.gitignore` is
/// honored at every directory level (root and nested, with nested rules
/// taking precedence — see `GitignoreStack`), hidden entries (any name
/// starting with `.`) are skipped — which also covers `.git/` and
/// `.code-context/` without a special case — and symbolic links are not
/// followed.
enum Walker {
    /// One entry found while walking a workspace: its full URL, its path
    /// relative to the walk's root, and whether it is a directory.
    struct Entry: Sendable, Equatable {
        /// The entry's full filesystem URL.
        let url: URL

        /// The entry's path relative to the walk's root, using `/`
        /// separators.
        let relativePath: String

        /// `true` if the entry is a directory.
        let isDirectory: Bool
    }

    /// Enumerates every non-ignored file and directory under
    /// `rootDirectory`, honoring `.gitignore` (root and nested) and
    /// skipping hidden entries and symbolic links.
    ///
    /// Ignored directories are pruned entirely — their contents are never
    /// visited — matching `git`'s own behavior (a negated pattern cannot
    /// re-include a path beneath an excluded directory).
    ///
    /// - Parameter rootDirectory: The directory to walk.
    /// - Returns: Every non-ignored entry beneath `rootDirectory`, in no
    ///   particular order.
    /// - Throws: Rethrows `FileManager`'s directory-enumeration errors.
    static func walkEntries(rootDirectory: URL) throws -> [Entry] {
        var results: [Entry] = []
        let rootComponents = RelativePath.components(of: rootDirectory)
        try walkDirectory(
            WalkedDirectory(url: rootDirectory, pathComponents: rootComponents),
            ignoreStack: GitignoreStack(),
            rootComponentCount: rootComponents.count,
            into: &results
        )
        return results
    }

    /// Enumerates non-ignored files under `rootDirectory`, filtered to
    /// `extensions`.
    ///
    /// - Parameters:
    ///   - rootDirectory: The directory to walk.
    ///   - extensions: File extensions to include, without a leading dot,
    ///     matched case-insensitively. Defaults to every extension
    ///     registered across `Languages.all` when `nil`.
    /// - Returns: The matched files' full URLs, in no particular order.
    /// - Throws: Rethrows `walkEntries(rootDirectory:)`'s errors.
    static func enumerateFiles(rootDirectory: URL, extensions: Set<String>? = nil) throws -> [URL] {
        let allowedExtensions = extensions ?? knownLanguageExtensions
        return try walkEntries(rootDirectory: rootDirectory)
            .filter { !$0.isDirectory && allowedExtensions.contains(Languages.normalizedFileExtension(of: $0.url)) }
            .map(\.url)
    }

    /// Walks `rootDirectory` and concurrently hashes every file whose
    /// extension `Languages.all` recognizes.
    ///
    /// Hashing runs across a `TaskGroup`, one child task per file,
    /// mirroring the Rust reference's `rayon`-parallel hashing.
    ///
    /// - Parameter rootDirectory: The workspace root to walk.
    /// - Returns: One `HashedFile` per matched file, in no particular
    ///   order.
    /// - Throws: Rethrows `enumerateFiles(rootDirectory:extensions:)`'s
    ///   errors. Per-file read failures are skipped rather than
    ///   propagated, matching the Rust reference's warn-and-skip behavior.
    static func walk(rootDirectory: URL) async throws -> [HashedFile] {
        let files = try enumerateFiles(rootDirectory: rootDirectory)
        return await hash(paths: files, rootDirectory: rootDirectory)
    }

    /// Every file extension (lowercased, no leading dot) registered across
    /// `Languages.all`.
    private static var knownLanguageExtensions: Set<String> {
        Set(Languages.all.flatMap { module in module.fileExtensions.map { $0.lowercased() } })
    }

    /// One directory that `walkDirectory(_:ignoreStack:rootComponentCount:into:)`
    /// visits: its URL and the path components of its standardized form.
    ///
    /// The walk builds the components of each child from the components of
    /// its directory (the walk skips symbolic links, `.` and `..`, thus the
    /// result is the same as `RelativePath.components(of:)`). Thus the walk
    /// makes no standardized URL for each entry. On a tree of the size of a
    /// Django clone, the standardized URLs of the gitignore check used most of
    /// the time of the walk.
    private struct WalkedDirectory {
        /// The URL of the directory.
        let url: URL

        /// The path components of the standardized URL of the directory.
        let pathComponents: [String]
    }

    /// Appends each non-ignored entry below `directory` to `results`, depth
    /// first, in name order.
    ///
    /// - Parameters:
    ///   - directory: The directory to walk.
    ///   - ignoreStack: The `.gitignore` rules of the ancestors of `directory`.
    ///   - rootComponentCount: The number of path components of the root of the
    ///     walk. An entry's relative path is its components after these.
    ///   - results: The entries found until now.
    /// - Throws: Rethrows `FileManager`'s directory-enumeration errors.
    private static func walkDirectory(
        _ directory: WalkedDirectory,
        ignoreStack: GitignoreStack,
        rootComponentCount: Int,
        into results: inout [Entry]
    ) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory.url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        let stack = ignoreStack.appending(gitignoreAt: directory.url)

        for childURL in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = childURL.lastPathComponent
            if name.hasPrefix(".") {
                continue
            }

            let resourceValues = try childURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if resourceValues.isSymbolicLink == true {
                continue
            }
            let isDirectory = resourceValues.isDirectory == true

            let child = WalkedDirectory(url: childURL, pathComponents: directory.pathComponents + [name])
            if stack.isIgnored(pathComponents: child.pathComponents, isDirectory: isDirectory) {
                continue
            }

            let entryRelativePath = child.pathComponents.dropFirst(rootComponentCount).joined(separator: "/")
            results.append(Entry(url: childURL, relativePath: entryRelativePath, isDirectory: isDirectory))

            if isDirectory {
                try walkDirectory(child, ignoreStack: stack, rootComponentCount: rootComponentCount, into: &results)
            }
        }
    }

    private static func hash(paths: [URL], rootDirectory: URL) async -> [HashedFile] {
        await withTaskGroup(of: HashedFile?.self) { group in
            for path in paths {
                group.addTask {
                    hashFile(at: path, rootDirectory: rootDirectory)
                }
            }
            var results: [HashedFile] = []
            for await file in group {
                if let file {
                    results.append(file)
                }
            }
            return results
        }
    }

    private static func hashFile(at url: URL, rootDirectory: URL) -> HashedFile? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        let truncatedHash = Data(digest.prefix(16))
        return HashedFile(
            relativePath: relativePath(of: url, rootDirectory: rootDirectory),
            contentHash: truncatedHash,
            fileSize: Int64(data.count)
        )
    }

    /// Computes `url`'s path relative to `rootDirectory` via
    /// `RelativePath.of(_:relativeTo:)`, falling back to `url`'s last path
    /// component (rather than propagating `nil`) since every caller here
    /// already knows `url` was discovered beneath `rootDirectory` by the
    /// walk itself.
    private static func relativePath(of url: URL, rootDirectory: URL) -> String {
        RelativePath.of(url, relativeTo: rootDirectory) ?? url.lastPathComponent
    }
}
