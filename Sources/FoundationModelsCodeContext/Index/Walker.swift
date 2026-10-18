import CryptoKit
import Foundation
import Logging

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

/// The result of `Walker.walk(rootDirectory:)`: the hashed files, and the
/// paths that the walk could not examine.
struct HashedWalk: Sendable, Equatable {
    /// One `HashedFile` for each indexable file that the walk found and read.
    let files: [HashedFile]

    /// The relative paths of the entries that the walk could not examine: a
    /// directory that it could not list, an entry whose type it could not
    /// read, and a file that it could not read for the hash.
    let unexaminedPaths: [String]

    /// Whether `relativePath` is an unexamined path or is below one.
    ///
    /// The reconcile keeps the rows of these paths: the walk does not know if
    /// the files are on disk, and a temporary permission error must not delete
    /// valid index rows.
    /// - Parameter relativePath: A row key, relative to the root.
    /// - Returns: `true` when the walk could not examine `relativePath`.
    func isUnexamined(_ relativePath: String) -> Bool {
        unexaminedPaths.contains { unexaminedPath in
            relativePath == unexaminedPath || relativePath.hasPrefix(unexaminedPath + "/")
        }
    }
}

/// Ignore-aware filesystem walker used to discover and hash indexable files
/// under a workspace root.
///
/// Port of `cleanup.rs::walk_and_hash`. The walk uses `PathFilter`, the same
/// filter as the watcher: it skips hidden entries, the hard-skip directories
/// and each entry that the `.gitignore`, `.ignore` and `.git/info/exclude`
/// rules ignore, and it does not follow symbolic links. It does not go into an
/// ignored directory.
///
/// The key of each entry comes from `WorkspaceRoot`, the one relative-path
/// function of the watcher and the reconcile too. The walk builds the path
/// components of each child from the components of its directory and gives
/// them to `WorkspaceRoot.relativeComponents(ofPathComponents:)`, thus it
/// makes no standardized URL for each entry.
///
/// The walk skips an entry that it cannot examine, logs it and counts it in
/// `Tree.unexaminedPaths`, and continues. Only a root that it cannot list
/// stops the walk.
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

    /// The result of one walk of a tree.
    struct Tree: Sendable {
        /// Each entry that the filter accepts, depth first, in name order.
        let entries: [Entry]

        /// The filter with the rules of each directory that the walk visited.
        let filter: PathFilter

        /// The relative paths of the entries that the walk could not examine.
        let unexaminedPaths: [String]

        /// The rule files that exist but that the walk could not read.
        let ruleLoadFailures: [PathFilter.LoadError]
    }

    /// The type of one entry, as the walk reads it.
    struct EntryType: Sendable, Equatable {
        /// `true` if the entry is a directory.
        let isDirectory: Bool

        /// `true` if the entry is a symbolic link.
        let isSymbolicLink: Bool
    }

    /// Reads the type of the entry at a URL.
    ///
    /// The walk calls this function for each child that is not hidden.
    /// Production code uses `Walker.entryType(at:)`. A test gives a function
    /// that throws for one entry, because a test cannot make the real read
    /// fail without a race.
    typealias EntryTypeReader = @Sendable (URL) throws -> EntryType

    /// Reads the type of the entry at `url` with `URL.resourceValues(forKeys:)`.
    /// - Parameter url: The URL of the entry.
    /// - Returns: Whether the entry is a directory, and whether it is a
    ///   symbolic link.
    /// - Throws: The error of `URL.resourceValues(forKeys:)`.
    static func entryType(at url: URL) throws -> EntryType {
        let resourceValues = try url.resourceValues(forKeys: Set(TreeWalk.resourceKeys))
        return EntryType(isDirectory: resourceValues.isDirectory == true, isSymbolicLink: resourceValues.isSymbolicLink == true)
    }

    /// Walks the tree below `rootDirectory` with `PathFilter`.
    ///
    /// The walk lists the canonical root, because `FileManager` cannot list a
    /// root that is a symbolic link. The URL of each entry stays below
    /// `rootDirectory`.
    ///
    /// - Parameters:
    ///   - rootDirectory: The directory to walk.
    ///   - readEntryType: Reads the type of each child. An entry whose type
    ///     it cannot read is an unexamined path.
    /// - Returns: The accepted entries, the filter with the rules of the tree,
    ///   and the paths that the walk could not examine.
    /// - Throws: The error of `FileManager` when the walk cannot list the root.
    static func walkTree(rootDirectory: URL, readEntryType: @escaping EntryTypeReader = Walker.entryType(at:)) throws -> Tree {
        let filter = PathFilter(rootDirectory: rootDirectory)
        let rootChildren = try FileManager.default.contentsOfDirectory(
            at: filter.root.canonicalURL,
            includingPropertiesForKeys: TreeWalk.resourceKeys,
            options: []
        ).map { rootDirectory.appendingPathComponent($0.lastPathComponent) }
        var walk = TreeWalk(filter: filter, readEntryType: readEntryType)
        let root = WalkedPath(url: rootDirectory, pathComponents: filter.root.components, relativeComponents: [])
        walk.visit(root, children: rootChildren)
        return Tree(
            entries: walk.entries,
            filter: walk.filter,
            unexaminedPaths: walk.unexaminedPaths,
            ruleLoadFailures: walk.ruleLoadFailures
        )
    }

    /// Enumerates every non-ignored file and directory under `rootDirectory`.
    ///
    /// - Parameter rootDirectory: The directory to walk.
    /// - Returns: Every non-ignored entry beneath `rootDirectory`, depth first,
    ///   in name order.
    /// - Throws: Rethrows `walkTree(rootDirectory:)`'s errors.
    static func walkEntries(rootDirectory: URL) throws -> [Entry] {
        try walkTree(rootDirectory: rootDirectory).entries
    }

    /// Enumerates non-ignored files under `rootDirectory`, filtered to
    /// `extensions`.
    ///
    /// The relative path of each entry comes from the walk, thus from
    /// `WorkspaceRoot.relativeComponents(ofPathComponents:)`: it is the row
    /// key of the file, also for a root that is a symbolic link.
    /// - Parameters:
    ///   - rootDirectory: The directory to walk.
    ///   - extensions: File extensions to include, without a leading dot,
    ///     matched case-insensitively. Defaults to every extension
    ///     registered across `Languages.all` when `nil`.
    /// - Returns: The entries of the matched files, depth first, in name order.
    /// - Throws: Rethrows `walkEntries(rootDirectory:)`'s errors.
    static func enumerateFiles(rootDirectory: URL, extensions: Set<String>? = nil) throws -> [Entry] {
        let allowedExtensions = extensions ?? knownLanguageExtensions
        return try walkEntries(rootDirectory: rootDirectory)
            .filter { !$0.isDirectory && allowedExtensions.contains(Languages.normalizedFileExtension(of: $0.url)) }
    }

    /// Walks `rootDirectory` and concurrently hashes every file whose
    /// extension `Languages.all` recognizes.
    ///
    /// Hashing runs across a `TaskGroup`, one child task per file,
    /// mirroring the Rust reference's `rayon`-parallel hashing.
    ///
    /// - Parameters:
    ///   - rootDirectory: The workspace root to walk.
    ///   - readEntryType: Reads the type of each child. An entry whose type
    ///     it cannot read is an unexamined path.
    /// - Returns: One `HashedFile` per matched file, in no particular order,
    ///   and the paths that the walk could not examine. A file that the hash
    ///   cannot read is an unexamined path.
    /// - Throws: Rethrows `walkTree(rootDirectory:readEntryType:)`'s errors.
    static func walk(rootDirectory: URL, readEntryType: @escaping EntryTypeReader = Walker.entryType(at:)) async throws -> HashedWalk {
        let tree = try walkTree(rootDirectory: rootDirectory, readEntryType: readEntryType)
        let files = tree.entries.filter { entry in
            !entry.isDirectory && knownLanguageExtensions.contains(Languages.normalizedFileExtension(of: entry.url))
        }
        let hashes = await hash(entries: files)
        return HashedWalk(
            files: hashes.compactMap(\.file),
            unexaminedPaths: tree.unexaminedPaths + hashes.filter { $0.file == nil }.map(\.relativePath)
        )
    }

    /// Every file extension (lowercased, no leading dot) registered across
    /// `Languages.all`.
    private static var knownLanguageExtensions: Set<String> {
        Set(Languages.all.flatMap { module in module.fileExtensions.map { $0.lowercased() } })
    }

    /// One path that the walk visits (the root, a directory or a file): its
    /// URL, the path components of its standardized URL, and its path
    /// components relative to the root.
    private struct WalkedPath {
        /// The URL of the path.
        let url: URL

        /// The path components of the standardized URL of the path. The walk
        /// skips symbolic links, `.` and `..`, thus the components of a child
        /// are the components of its directory and its name.
        let pathComponents: [String]

        /// The path components relative to the root. The root has no
        /// components.
        let relativeComponents: [String]
    }

    /// The state of one walk: the filter that grows with the rules of each
    /// visited directory, and the results.
    private struct TreeWalk {
        /// The resource values that the walk reads for each entry.
        static let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]

        /// The filter, with the rules of each directory visited until now.
        var filter: PathFilter

        /// Reads the type of each child.
        let readEntryType: EntryTypeReader

        /// The accepted entries found until now.
        var entries: [Entry] = []

        /// The relative paths of the entries that the walk could not examine.
        var unexaminedPaths: [String] = []

        /// The rule files that exist but that the walk could not read.
        var ruleLoadFailures: [PathFilter.LoadError] = []

        /// Adds the rules of `directory`, and then visits each child, in name
        /// order.
        /// - Parameters:
        ///   - directory: The directory that the walk visits.
        ///   - children: The URLs of the children of `directory`.
        mutating func visit(_ directory: WalkedPath, children: [URL]) {
            loadRules(of: directory)
            for childURL in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let pathComponents = directory.pathComponents + [childURL.lastPathComponent]
                guard let relativeComponents = filter.root.relativeComponents(ofPathComponents: pathComponents) else {
                    continue
                }
                visitChild(WalkedPath(url: childURL, pathComponents: pathComponents, relativeComponents: relativeComponents))
            }
        }

        /// Adds the rules of the rule files of `directory` to the filter. A rule
        /// file that the walk cannot read is logged and recorded, and the walk
        /// continues with the other rules.
        /// - Parameter directory: The directory whose rule files the walk reads.
        private mutating func loadRules(of directory: WalkedPath) {
            do throws(PathFilter.LoadError) {
                try filter.loadRules(inDirectory: directory.url, relativeComponents: directory.relativeComponents)
            } catch {
                ruleLoadFailures.append(error)
                Log.index.warning(
                    "the walk cannot read an ignore rule file and continues without its rules",
                    metadata: [CodeContextTracing.MetadataKey.filePath: .string(error.relativePath)]
                )
            }
        }

        /// Examines one child: it skips a hidden entry, a symbolic link and an
        /// ignored entry, adds an accepted entry, and visits an accepted
        /// directory.
        /// - Parameter child: The child, with its URL and its path components.
        private mutating func visitChild(_ child: WalkedPath) {
            guard !PathFilter.isHidden(child.url.lastPathComponent) else {
                return
            }
            let entryType: EntryType
            do {
                entryType = try readEntryType(child.url)
            } catch {
                skip(child.relativeComponents, error: error)
                return
            }
            guard !entryType.isSymbolicLink,
                !filter.isEntryIgnored(relativeComponents: child.relativeComponents, isDirectory: entryType.isDirectory)
            else {
                return
            }
            entries.append(Entry(url: child.url, relativePath: child.relativeComponents.joined(separator: "/"), isDirectory: entryType.isDirectory))
            if entryType.isDirectory {
                visitDirectory(child)
            }
        }

        /// Lists an accepted directory and visits it. A directory that the walk
        /// cannot list is skipped, logged and recorded.
        /// - Parameter directory: The accepted directory.
        private mutating func visitDirectory(_ directory: WalkedPath) {
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory.url,
                    includingPropertiesForKeys: Self.resourceKeys,
                    options: []
                )
            } catch {
                skip(directory.relativeComponents, error: error)
                return
            }
            visit(directory, children: children)
        }

        /// Records an entry that the walk cannot examine and logs it.
        /// - Parameters:
        ///   - relativeComponents: The path components of the entry relative to
        ///     the root.
        ///   - error: The error of the examination. The log holds only its type
        ///     and case names, never its description.
        private mutating func skip(_ relativeComponents: [String], error: any Error) {
            let relativePath = relativeComponents.joined(separator: "/")
            unexaminedPaths.append(relativePath)
            Walker.logSkippedEntry(relativePath: relativePath, error: error)
        }
    }

    /// Logs an entry that the walk skips because it cannot examine it.
    /// - Parameters:
    ///   - relativePath: The path of the entry, relative to the root.
    ///   - error: The error of the examination. The log holds only its type
    ///     and case names, never its description.
    private static func logSkippedEntry(relativePath: String, error: any Error) {
        var metadata = Log.errorDetail(of: error)
        metadata[CodeContextTracing.MetadataKey.filePath] = .string(relativePath)
        Log.index.warning("the walk cannot examine an entry and skips it", metadata: metadata)
    }

    /// The outcome of the hash of one file.
    private struct HashOutcome: Sendable {
        /// The relative path of the file.
        let relativePath: String

        /// The hashed file, or `nil` when the file cannot be read.
        let file: HashedFile?
    }

    /// Hashes each file of `entries` concurrently. A file that cannot be read
    /// is logged.
    /// - Parameter entries: The file entries to hash.
    /// - Returns: One outcome for each entry, in no particular order.
    private static func hash(entries: [Entry]) async -> [HashOutcome] {
        await withTaskGroup(of: HashOutcome.self) { group in
            for entry in entries {
                group.addTask {
                    do {
                        return HashOutcome(relativePath: entry.relativePath, file: try hashFile(at: entry.url, relativePath: entry.relativePath))
                    } catch {
                        logSkippedEntry(relativePath: entry.relativePath, error: error)
                        return HashOutcome(relativePath: entry.relativePath, file: nil)
                    }
                }
            }
            var outcomes: [HashOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    /// The number of leading bytes of the SHA-256 digest that a content hash
    /// keeps.
    private static let contentHashByteCount = 16

    /// Reads one file and computes its content hash: the first
    /// `contentHashByteCount` bytes of its SHA-256 digest.
    ///
    /// The watcher calls this function too, thus `Store.markDirty` gets the
    /// same hash from a watcher event as from a reconcile.
    /// - Parameters:
    ///   - url: The URL of the file.
    ///   - relativePath: The row key of the file.
    /// - Returns: The hashed file.
    /// - Throws: The error of the read, when the file cannot be read.
    static func hashFile(at url: URL, relativePath: String) throws -> HashedFile {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return HashedFile(relativePath: relativePath, contentHash: Data(digest.prefix(contentHashByteCount)), fileSize: Int64(data.count))
    }
}
