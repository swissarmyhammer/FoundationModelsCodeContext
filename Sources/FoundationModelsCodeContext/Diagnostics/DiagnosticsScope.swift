import Darwin
import Foundation
import libgit2

/// Which files a `DiagnosticsOps.diagnostics(...)` call targets.
///
/// Port of the scope concept `swissarmyhammer-tools`' diagnostics MCP tool
/// layers on top of the `swissarmyhammer-diagnostics` crate (the crate
/// itself only ever takes already-resolved paths — see
/// `DiagnosticsScopeResolver`'s doc comment for where resolution actually
/// happens in the Rust reference).
public enum DiagnosticsScope: Sendable, Equatable {
    /// Every file with a modified, untracked, or staged change, relative to
    /// the index/HEAD.
    case workingTree

    /// An explicit file path, or a glob pattern (containing `*`, `?`, or
    /// `[`) resolved relative to the workspace root.
    case file(String)

    /// Every file changed in/since a commit or range (`"<sha>"`, treated as
    /// `"<sha>..HEAD"`, or an explicit `"<from>..<to>"` range).
    case sha(String)
}

/// Resolves a `DiagnosticsScope` into the concrete, workspace-relative file
/// paths it targets.
///
/// Port of the scope-resolution layer in `swissarmyhammer-tools`'
/// diagnostics MCP tool (`crates/swissarmyhammer-tools/src/mcp/tools/diagnostics/mod.rs`'s
/// `DiagnosticsTool::resolve_paths`) — the `swissarmyhammer-diagnostics`
/// crate's own `diagnose`/`settle`/`record` modules never resolve a scope
/// themselves; they only ever take an already-resolved `paths: &[String]`.
/// That Rust reference resolves `.workingTree`/`.sha` via `git2` (libgit2)
/// through `swissarmyhammer-git`; this Swift port also uses libgit2 in the
/// process (see `GitStatus`), and starts no `git` child process.
enum DiagnosticsScopeResolver {
    /// Resolves `scope` into absolutized, root-confined, deduplicated
    /// (order-preserving) workspace-relative paths, with the extension filter
    /// that `keepsOnlyDiagnosable` selects.
    /// - Parameters:
    ///   - scope: The scope to resolve.
    ///   - rootDirectory: The workspace root every resolved path is confined to and reported relative to.
    ///   - keepsOnlyDiagnosable: When `true` (the default, for `get diagnostics`), keeps only the files whose
    ///     extension has a language server. When `false` (for blast radius), keeps each file whose extension
    ///     the index reads, because the tree-sitter layer also makes call edges.
    /// - Returns: The resolved paths, relative to `rootDirectory`, in scope-specific order (targets should be treated as already deduplicated).
    /// - Throws: Rethrows a libgit2 read failure (`CodeContextError.git`) for `.workingTree`/`.sha`.
    static func resolvePaths(
        scope: DiagnosticsScope,
        rootDirectory: URL,
        keepsOnlyDiagnosable: Bool = true
    ) async throws -> [String] {
        let keptExtensions = keepsOnlyDiagnosable ? diagnosableExtensions : indexedExtensions
        let rawPaths: [String]
        switch scope {
        case .workingTree:
            rawPaths = try await GitStatus.workingTreeChanges(rootDirectory: rootDirectory)
        case .file(let target):
            rawPaths = GlobExpansion.expand(pattern: target, rootDirectory: rootDirectory)
        case .sha(let range):
            rawPaths = try await GitStatus.changedFiles(sinceRange: range, rootDirectory: rootDirectory)
        }

        let root = WorkspaceRoot(rootDirectory)
        var seen = Set<String>()
        var resolved: [String] = []
        for raw in rawPaths {
            guard let relative = confinedRelativePath(raw, root: root) else { continue }
            guard hasExtension(relative, in: keptExtensions) else { continue }
            guard seen.insert(relative).inserted else { continue }
            resolved.append(relative)
        }
        return resolved
    }

    /// Resolves `raw` (an absolute or root-relative path string) against the
    /// root, returning its workspace-relative form only if it stays confined
    /// under the root or the canonical root.
    ///
    /// The key comes from `WorkspaceRoot.relativePath(of:)`, the same function
    /// that makes the row keys of the walk and the watcher.
    /// - Parameters:
    ///   - raw: The candidate path, as read by `GitStatus` or expanded from a glob.
    ///   - root: The workspace root to confine and relativize against.
    /// - Returns: The workspace-relative path, or `nil` if `raw` escapes the root.
    private static func confinedRelativePath(_ raw: String, root: WorkspaceRoot) -> String? {
        let candidateURL = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : root.url.appendingPathComponent(raw)
        return root.relativePath(of: candidateURL)
    }

    /// Whether the extension of `relativePath` is in `extensions`.
    /// - Parameters:
    ///   - relativePath: The workspace-relative path to check.
    ///   - extensions: The kept extensions, lowercased, with no leading dot.
    /// - Returns: `true` if the path has an extension and `extensions` contains it.
    private static func hasExtension(_ relativePath: String, in extensions: Set<String>) -> Bool {
        let fileExtension = Languages.normalizedFileExtension(ofPath: relativePath)
        guard !fileExtension.isEmpty else { return false }
        return extensions.contains(fileExtension)
    }

    /// Every file extension (lowercased, no leading dot) registered by an
    /// LSP-backed `Languages.all` module (`languageServer != nil`).
    ///
    /// Deliberately narrower than `indexedExtensions`: indexing covers every
    /// tree-sitter-chunkable format, including LSP-less ones like
    /// Markdown/SQL/JSON/YAML/Bash (`languageServer == nil`), but diagnostics
    /// can only ever come from a running language server. Filtering
    /// `Languages.all` down to `languageServer != nil` before flat-mapping
    /// `fileExtensions` is this module's own "does this extension have an
    /// LSP" answer — it's the same signal each `LanguageModule`'s
    /// `languageServer` doc comment already ties back to `builtin/lsp/*.yaml`,
    /// without needing a second, separate lookup into that registry.
    private static let diagnosableExtensions = extensions(of: Languages.all.filter { module in module.languageServer != nil })

    /// Every file extension (lowercased, no leading dot) that the index reads:
    /// the same set as the indexable extensions of
    /// `Walker.enumerateFiles(rootDirectory:extensions:)`
    /// (`Languages.all.flatMap { $0.fileExtensions }`).
    private static let indexedExtensions = extensions(of: Languages.all)

    /// The file extensions of `modules`, lowercased, with no leading dot.
    /// - Parameter modules: The language modules to read.
    /// - Returns: The union of the `fileExtensions` of `modules`.
    private static func extensions(of modules: [any LanguageModule.Type]) -> Set<String> {
        Set(modules.flatMap { module in module.fileExtensions.map { $0.lowercased() } })
    }
}

/// The libgit2 reads behind the `.workingTree` and the `.sha` scopes.
///
/// Each read runs libgit2 in the process, and starts no `git` child process
/// (see `LibGit2`). The repository is the one that holds the root: the open
/// searches from the root up through the parent folders, as the `git` program
/// does. Each read gives absolute paths in the work folder of the repository.
/// Thus `DiagnosticsScopeResolver.resolvePaths(scope:rootDirectory:keepsOnlyDiagnosable:)`
/// keeps only the paths under the root, also when the root is a folder below
/// the top of the repository.
enum GitStatus {
    /// The name of the thread that runs each libgit2 read.
    private static let readThreadName = "git-status"

    /// The version of `git_status_options` that `workingTreePaths(of:)` fills.
    private static let statusOptionsVersion = UInt32(GIT_STATUS_OPTIONS_VERSION)

    /// The `git_status_opt_t` flags of the working-tree read: untracked
    /// files, one entry for each file in a new folder (not one entry for the
    /// folder), and staged renames. Ignored files are not in the list.
    private static let statusFlags =
        GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
        | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue

    /// The status flags that put a file in the `.workingTree` scope: a
    /// staged new, changed or renamed file, an unstaged change, and an
    /// untracked file.
    private static let keptStatusFlags =
        GIT_STATUS_INDEX_NEW.rawValue | GIT_STATUS_INDEX_MODIFIED.rawValue | GIT_STATUS_INDEX_RENAMED.rawValue
        | GIT_STATUS_WT_MODIFIED.rawValue | GIT_STATUS_WT_NEW.rawValue

    /// The status flags that take a file out of the `.workingTree` scope,
    /// also when it has a kept flag: a deletion in the index or in the work
    /// folder, and a merge conflict. A deleted file cannot carry diagnostics,
    /// and a conflict has no single resolved content to diagnose.
    private static let excludedStatusFlags =
        GIT_STATUS_INDEX_DELETED.rawValue | GIT_STATUS_WT_DELETED.rawValue | GIT_STATUS_CONFLICTED.rawValue

    /// The delta kinds that put a file in the `.sha` scope: added, copied,
    /// modified and renamed. A deleted file is not in the scope, for the
    /// reason of `excludedStatusFlags`.
    private static let keptDeltaKinds: Set<UInt32> = [
        GIT_DELTA_ADDED.rawValue, GIT_DELTA_COPIED.rawValue, GIT_DELTA_MODIFIED.rawValue, GIT_DELTA_RENAMED.rawValue,
    ]

    /// The separator of an explicit `"from..to"` range.
    private static let rangeSeparator = ".."

    /// The revision that a single ref is compared against.
    private static let headRevision = "HEAD"

    /// The type that `git_object_peel` peels a revision to for the diff.
    private static let treeObjectType = GIT_OBJECT_TREE

    /// Files with a staged change, an unstaged change, or no tracking.
    ///
    /// Ports the Rust reference's `Scope::Working` handling (`git2`'s
    /// `GitOperations::get_status`, the union of `staged_modified`,
    /// `unstaged_modified`, `untracked`, `staged_new` and `renamed`). A new
    /// untracked folder gives each file that it holds, not the folder itself.
    /// A staged rename gives its new path.
    /// - Parameter rootDirectory: A folder in the work folder of the repository.
    /// - Returns: The changed paths, absolute, in the order of libgit2 (by path).
    /// - Throws: `CodeContextError.git` if no repository holds `rootDirectory`, or the read fails.
    static func workingTreeChanges(rootDirectory: URL) async throws -> [String] {
        try await read(rootDirectory: rootDirectory, workingTreePaths(of:))
    }

    /// Files changed in/since `range`.
    ///
    /// Ports the Rust reference's `Scope::Sha` handling
    /// (`GitOperations::get_changed_files_from_range`'s `git2` tree-to-tree
    /// diff). A bare ref (no `..`) is expanded to `"<ref>..HEAD"` first,
    /// matching the Rust reference's "single ref treated as `ref..HEAD`"
    /// rule. A `"from...to"` range compares the merge base of the two with
    /// `to`, as `git diff` does. Renames are found, and a deletion is not in
    /// the result.
    /// - Parameters:
    ///   - range: A single ref (compared against `HEAD`) or an explicit `"from..to"` range.
    ///   - rootDirectory: A folder in the work folder of the repository.
    /// - Returns: The changed paths, absolute, in the order of libgit2 (by path).
    /// - Throws: `CodeContextError.git` if no repository holds `rootDirectory`, or a revision does not exist.
    static func changedFiles(sinceRange range: String, rootDirectory: URL) async throws -> [String] {
        let resolvedRange = range.contains(rangeSeparator) ? range : "\(range)\(rangeSeparator)\(headRevision)"
        return try await read(rootDirectory: rootDirectory) { repository in
            try changedPaths(of: repository, range: resolvedRange)
        }
    }

    /// Opens the repository that holds `rootDirectory` and runs `body` with
    /// it on a dedicated thread, not on a thread of the cooperative pool
    /// (see `ProcessUtilities.runOnDedicatedThread(name:_:)`): a read of a
    /// large work folder can take a long time.
    /// - Parameters:
    ///   - rootDirectory: A folder in the work folder of the repository.
    ///   - body: The read. It gets the open repository, and gives paths
    ///     relative to the work folder.
    /// - Returns: The paths of `body`, absolute in the work folder.
    /// - Throws: `CodeContextError.git` if no repository holds `rootDirectory`, or the error of `body`.
    private static func read(
        rootDirectory: URL,
        _ body: @escaping @Sendable (OpaquePointer) throws -> [String]
    ) async throws -> [String] {
        let result = await ProcessUtilities.runOnDedicatedThread(name: readThreadName) {
            Result {
                try LibGit2.withRepository(at: rootDirectory) { repository in
                    let workFolder = try workFolder(of: repository)
                    return try body(repository).map { path in workFolder.appendingPathComponent(path).path }
                }
            }
        }.value
        return try result.get()
    }

    /// The work folder of `repository`.
    /// - Parameter repository: The open repository.
    /// - Returns: The work folder.
    /// - Throws: `CodeContextError.git` if the repository is bare.
    private static func workFolder(of repository: OpaquePointer) throws -> URL {
        guard let path = git_repository_workdir(repository) else {
            throw CodeContextError.git("the repository has no work folder")
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    /// The paths of the `.workingTree` scope.
    /// - Parameter repository: The open repository.
    /// - Returns: The paths, relative to the work folder.
    /// - Throws: `CodeContextError.git` if the status cannot be read.
    private static func workingTreePaths(of repository: OpaquePointer) throws -> [String] {
        var options = git_status_options()
        try LibGit2.check(git_status_options_init(&options, statusOptionsVersion))
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags = statusFlags
        let list = try LibGit2.makeHandle { list in git_status_list_new(&list, repository, &options) }
        defer { git_status_list_free(list) }
        return (0..<git_status_list_entrycount(list)).compactMap { index in
            git_status_byindex(list, index).flatMap { entry in keptPath(of: entry.pointee) }
        }
    }

    /// The path of one status entry, or `nil` when the entry is not in the
    /// `.workingTree` scope.
    ///
    /// The path is the new path of the index change, or, when the index has
    /// no change, the new path of the work folder change. Thus a staged
    /// rename gives its new path.
    /// - Parameter entry: The entry, which the status list owns.
    /// - Returns: A copy of the path, or `nil` to exclude the entry.
    private static func keptPath(of entry: git_status_entry) -> String? {
        let flags = entry.status.rawValue
        guard flags & keptStatusFlags != 0, flags & excludedStatusFlags == 0 else { return nil }
        guard let delta = entry.head_to_index ?? entry.index_to_workdir, let path = delta.pointee.new_file.path else {
            return nil
        }
        return String(cString: path)
    }

    /// The paths of the `.sha` scope: the added, copied, modified and
    /// renamed files of the diff from the first tree of `range` to its
    /// second tree.
    /// - Parameters:
    ///   - repository: The open repository.
    ///   - range: An explicit `"from..to"` or `"from...to"` range.
    /// - Returns: The new paths, relative to the work folder.
    /// - Throws: `CodeContextError.git` if a revision does not exist, or the diff fails.
    private static func changedPaths(of repository: OpaquePointer, range: String) throws -> [String] {
        let (oldTree, newTree) = try trees(of: repository, range: range)
        defer {
            git_tree_free(oldTree)
            git_tree_free(newTree)
        }
        let diff = try LibGit2.makeHandle { diff in git_diff_tree_to_tree(&diff, repository, oldTree, newTree, nil) }
        defer { git_diff_free(diff) }
        try LibGit2.check(git_diff_find_similar(diff, nil))
        return (0..<git_diff_num_deltas(diff)).compactMap { index in
            git_diff_get_delta(diff, index).flatMap { delta in keptPath(of: delta.pointee) }
        }
    }

    /// The new path of one diff delta, or `nil` when the delta is not in the
    /// `.sha` scope.
    /// - Parameter delta: The delta, which the diff owns.
    /// - Returns: A copy of the new path, or `nil` to exclude the delta.
    private static func keptPath(of delta: git_diff_delta) -> String? {
        guard keptDeltaKinds.contains(delta.status.rawValue), let path = delta.new_file.path else { return nil }
        return String(cString: path)
    }

    /// The two trees of `range`. For a `"from...to"` range, the first tree is
    /// the tree of the merge base of the two commits.
    /// - Parameters:
    ///   - repository: The open repository.
    ///   - range: An explicit `"from..to"` or `"from...to"` range.
    /// - Returns: The old tree and the new tree. The caller frees both.
    /// - Throws: `CodeContextError.git` if a revision does not exist, or the range has no merge base.
    private static func trees(of repository: OpaquePointer, range: String) throws -> (OpaquePointer, OpaquePointer) {
        var revisions = git_revspec()
        try LibGit2.check(git_revparse(&revisions, repository, range))
        defer {
            git_object_free(revisions.from)
            git_object_free(revisions.to)
        }
        guard let from = revisions.from, let to = revisions.to else {
            throw CodeContextError.git("the range '\(range)' does not name two revisions")
        }
        let isMergeBaseRange = revisions.flags & GIT_REVSPEC_MERGE_BASE.rawValue != 0
        let oldTree = try isMergeBaseRange ? mergeBaseTree(of: repository, from, to) : tree(of: from)
        do {
            return (oldTree, try tree(of: to))
        } catch {
            git_tree_free(oldTree)
            throw error
        }
    }

    /// The tree of the merge base of two revisions.
    /// - Parameters:
    ///   - repository: The open repository.
    ///   - first: The first revision.
    ///   - second: The second revision.
    /// - Returns: The tree. The caller frees it.
    /// - Throws: `CodeContextError.git` if the two have no merge base.
    private static func mergeBaseTree(
        of repository: OpaquePointer, _ first: OpaquePointer, _ second: OpaquePointer
    ) throws -> OpaquePointer {
        var baseID = git_oid()
        try LibGit2.check(git_merge_base(&baseID, repository, git_object_id(first), git_object_id(second)))
        let base = try LibGit2.makeHandle { commit in git_commit_lookup(&commit, repository, &baseID) }
        defer { git_commit_free(base) }
        return try LibGit2.makeHandle { tree in git_commit_tree(&tree, base) }
    }

    /// The tree that `revision` peels to.
    /// - Parameter revision: A commit, a tag or a tree.
    /// - Returns: The tree. The caller frees it.
    /// - Throws: `CodeContextError.git` if the revision does not peel to a tree.
    private static func tree(of revision: OpaquePointer) throws -> OpaquePointer {
        try LibGit2.makeHandle { tree in git_object_peel(&tree, revision, treeObjectType) }
    }
}

/// Filesystem glob expansion backing `.file(pattern)` scope resolution.
enum GlobExpansion {
    /// The glob metacharacters. A pattern that has one of them is a glob.
    private static let metacharacters: Set<Character> = ["*", "?", "["]

    /// Whether `pattern` is a glob, and not a literal path.
    ///
    /// The test is lexical only: a pattern is a glob when it has a glob
    /// metacharacter (`*`, `?`, `[`).
    ///
    /// - Parameter pattern: A literal path or a glob pattern.
    /// - Returns: `true` when `pattern` has a glob metacharacter.
    static func isGlob(_ pattern: String) -> Bool {
        pattern.contains(where: metacharacters.contains)
    }

    /// Expands `pattern` to the files it matches under `rootDirectory`.
    ///
    /// A pattern with no glob metacharacters (`*`, `?`, `[`) is returned
    /// as-is (a literal path), matching the Rust reference's
    /// `expand_file_target`'s lexical-only glob detection — resolution and
    /// existence-checking for a literal path are left to
    /// `DiagnosticsScopeResolver.resolvePaths(scope:rootDirectory:)`'s
    /// shared confinement/extension filtering, not this function. A pattern
    /// with metacharacters is expanded via the POSIX `glob(3)` C function
    /// (`Darwin.glob`), the platform-native equivalent of the Rust
    /// reference's `glob` crate — this package already targets macOS only
    /// (see `Package.swift`'s `platforms`), so calling directly into
    /// `Darwin` needs no additional dependency.
    /// - Parameters:
    ///   - pattern: A literal path or a glob pattern.
    ///   - rootDirectory: The workspace root a relative pattern is resolved against.
    /// - Returns: `[pattern]` if it has no glob metacharacters; otherwise every filesystem match, as absolute paths.
    static func expand(pattern: String, rootDirectory: URL) -> [String] {
        guard isGlob(pattern) else {
            return [pattern]
        }

        let absolutePattern = pattern.hasPrefix("/") ? pattern : rootDirectory.appendingPathComponent(pattern).path

        var globResult = glob_t()
        defer { globfree(&globResult) }
        guard Darwin.glob(absolutePattern, GLOB_TILDE, nil, &globResult) == 0 else {
            return []
        }
        return (0..<Int(globResult.gl_pathc)).compactMap { index in
            globResult.gl_pathv[index].map { String(cString: $0) }
        }
    }
}
