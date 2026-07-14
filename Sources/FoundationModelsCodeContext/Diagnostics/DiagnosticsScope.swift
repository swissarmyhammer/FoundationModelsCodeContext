import Darwin
import Foundation

/// Which files a `DiagnosticsOps.diagnostics(...)` call targets.
///
/// Port of the scope concept `swissarmyhammer-tools`' diagnostics MCP tool
/// layers on top of the `swissarmyhammer-diagnostics` crate (the crate
/// itself only ever takes already-resolved paths — see
/// `DiagnosticsScopeResolver`'s doc comment for where resolution actually
/// happens in the Rust reference).
public enum DiagnosticsScope: Sendable, Equatable {
    /// Every file with a modified, untracked, or staged change in `git
    /// status`, relative to the index/HEAD.
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
/// through `swissarmyhammer-git`; this Swift port has no `git2` binding
/// dependency, so both shell out to the `git` CLI via `Process` instead —
/// a deliberate divergence, using the same one-shot-subprocess shape as
/// `ProcessLanguageServerConnection`'s spawn path (`/usr/bin/env <command>
/// <args>`, wrapped errors, no ambient shell).
enum DiagnosticsScopeResolver {
    /// Resolves `scope` into absolutized, root-confined, diagnosable,
    /// deduplicated (order-preserving) workspace-relative paths.
    /// - Parameters:
    ///   - scope: The scope to resolve.
    ///   - rootDirectory: The workspace root every resolved path is confined to and reported relative to.
    /// - Returns: The resolved paths, relative to `rootDirectory`, in scope-specific order (targets should be treated as already deduplicated).
    /// - Throws: Rethrows a `git` invocation failure (`CodeContextError.spawnFailed`) for `.workingTree`/`.sha`.
    static func resolvePaths(scope: DiagnosticsScope, rootDirectory: URL) async throws -> [String] {
        let rawPaths: [String]
        switch scope {
        case .workingTree:
            rawPaths = try await GitStatus.workingTreeChanges(rootDirectory: rootDirectory)
        case let .file(target):
            rawPaths = GlobExpansion.expand(pattern: target, rootDirectory: rootDirectory)
        case let .sha(range):
            rawPaths = try await GitStatus.changedFiles(sinceRange: range, rootDirectory: rootDirectory)
        }

        var seen = Set<String>()
        var resolved: [String] = []
        for raw in rawPaths {
            guard let relative = confinedRelativePath(raw, rootDirectory: rootDirectory) else { continue }
            guard isDiagnosableExtension(relative) else { continue }
            guard seen.insert(relative).inserted else { continue }
            resolved.append(relative)
        }
        return resolved
    }

    /// Resolves `raw` (an absolute or root-relative path string) against
    /// `rootDirectory`, returning its workspace-relative form only if it
    /// stays confined under the root.
    /// - Parameters:
    ///   - raw: The candidate path, as reported by `git` or expanded from a glob.
    ///   - rootDirectory: The workspace root to confine and relativize against.
    /// - Returns: The workspace-relative path, or `nil` if `raw` escapes `rootDirectory`.
    private static func confinedRelativePath(_ raw: String, rootDirectory: URL) -> String? {
        let candidateURL = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : rootDirectory.appendingPathComponent(raw)
        return RelativePath.of(candidateURL, relativeTo: rootDirectory)
    }

    /// Whether `relativePath`'s extension belongs to a language module that
    /// actually has an LSP server to diagnose it with.
    ///
    /// Deliberately narrower than `Walker.enumerateFiles(rootDirectory:extensions:)`'s
    /// indexable extension set (`Languages.all.flatMap { $0.fileExtensions }`):
    /// indexing covers every tree-sitter-chunkable format, including
    /// LSP-less ones like Markdown/SQL/JSON/YAML/Bash (`languageServer ==
    /// nil`), but diagnostics can only ever come from a running language
    /// server. Filtering `Languages.all` down to `languageServer != nil`
    /// before flat-mapping `fileExtensions` is this module's own "does this
    /// extension have an LSP" answer — it's the same signal each
    /// `LanguageModule`'s `languageServer` doc comment already ties back to
    /// `builtin/lsp/*.yaml`, without needing a second, separate lookup into
    /// that registry.
    /// - Parameter relativePath: The workspace-relative path to check.
    /// - Returns: `true` if the path's extension is registered by an LSP-backed `Languages.all` module.
    private static func isDiagnosableExtension(_ relativePath: String) -> Bool {
        let fileExtension = (relativePath as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return false }
        return knownExtensions.contains(fileExtension)
    }

    /// Every file extension (lowercased, no leading dot) registered by an
    /// LSP-backed `Languages.all` module (`languageServer != nil`).
    private static let knownExtensions: Set<String> = Set(
        Languages.all
            .filter { module in module.languageServer != nil }
            .flatMap { module in module.fileExtensions.map { $0.lowercased() } }
    )
}

/// One-shot `git` invocations backing `.workingTree`/`.sha` scope resolution.
enum GitStatus {
    /// Files with a modified, untracked, or staged change per `git status`,
    /// relative to `rootDirectory`.
    ///
    /// Ports the Rust reference's `Scope::Working` handling (`git2`'s
    /// `GitOperations::get_status`, unioning `staged_modified +
    /// unstaged_modified + untracked + staged_new + renamed`) via `git
    /// status --porcelain=v1 --untracked-files=all` — `--untracked-files=all`
    /// matches `get_status`'s `recurse_untracked_dirs(true)`, expanding a
    /// brand-new untracked directory to the files it contains rather than
    /// reporting the directory itself. Deletions (`D` in either status
    /// column) and unmerged/conflicted entries (`U`, or `AA`/`DD`) are
    /// excluded, matching the Rust reference's reasoning: a deleted file
    /// can't carry diagnostics, and a conflict has no single resolved
    /// content to diagnose.
    /// - Parameter rootDirectory: The git working tree to query.
    /// - Returns: The changed paths, relative to `rootDirectory`.
    /// - Throws: `CodeContextError.spawnFailed` if `git` can't be run or exits non-zero.
    static func workingTreeChanges(rootDirectory: URL) async throws -> [String] {
        let output = try await GitShell.run(arguments: ["status", "--porcelain=v1", "--untracked-files=all"], in: rootDirectory)
        return output.split(separator: "\n").compactMap { parseStatusLine(String($0)) }
    }

    /// Files changed in/since `range`, relative to `rootDirectory`.
    ///
    /// Ports the Rust reference's `Scope::Sha` handling
    /// (`GitOperations::get_changed_files_from_range`'s `git2` tree-to-tree
    /// diff) via `git diff --name-only --diff-filter=ACMR`. A bare ref (no
    /// `..`) is expanded to `"<ref>..HEAD"` first, matching the Rust
    /// reference's "single ref treated as `ref..HEAD`" rule rather than
    /// `git diff`'s own default (working-tree-vs-ref) meaning for a single
    /// argument. `--diff-filter=ACMR` (added/copied/modified/renamed)
    /// excludes deletions, matching `.workingTree`'s exclusion for the same
    /// reason.
    /// - Parameters:
    ///   - range: A single ref (compared against `HEAD`) or an explicit `"from..to"` range.
    ///   - rootDirectory: The git working tree to query.
    /// - Returns: The changed paths, relative to `rootDirectory`.
    /// - Throws: `CodeContextError.spawnFailed` if `git` can't be run or exits non-zero.
    static func changedFiles(sinceRange range: String, rootDirectory: URL) async throws -> [String] {
        let resolvedRange = range.contains("..") ? range : "\(range)..HEAD"
        let output = try await GitShell.run(arguments: ["diff", "--name-only", "--diff-filter=ACMR", resolvedRange], in: rootDirectory)
        return output.split(separator: "\n").map(String.init)
    }

    /// Parses one `git status --porcelain=v1` line into the changed path it
    /// reports, or `nil` if the line represents a deletion, a conflict, or
    /// isn't a change this scope cares about.
    ///
    /// Porcelain v1 lines are `"XY PATH"` (or `"XY ORIG -> PATH"` for a
    /// rename/copy), where `X` is the index (staged) status and `Y` is the
    /// worktree (unstaged) status.
    /// - Parameter line: One raw `git status --porcelain=v1` output line.
    /// - Returns: The line's changed path (the *new* path for a rename), or `nil` to exclude it.
    private static func parseStatusLine(_ line: String) -> String? {
        guard line.count > 3 else { return nil }
        let indexStatus = line[line.startIndex]
        let worktreeStatus = line[line.index(after: line.startIndex)]
        let path = String(line.dropFirst(3))

        if indexStatus == "?", worktreeStatus == "?" {
            return path
        }
        guard indexStatus != "U", worktreeStatus != "U" else { return nil } // unmerged/conflicted
        guard indexStatus != "D", worktreeStatus != "D" else { return nil } // deleted

        guard indexStatus == "M" || worktreeStatus == "M" || indexStatus == "A" || indexStatus == "R" || indexStatus == "C" else {
            return nil
        }

        if indexStatus == "R" || indexStatus == "C", let arrowRange = path.range(of: " -> ") {
            return String(path[arrowRange.upperBound...])
        }
        return path
    }
}

/// A one-shot `git` subprocess invocation, mirroring
/// `ProcessLanguageServerConnection`'s spawn shape (`/usr/bin/env <command>
/// <args>`, wrapped spawn failures) but without that type's long-lived
/// bidirectional pipe machinery — a `git status`/`git diff` call is a single
/// request/response round trip, not a persistent server connection.
enum GitShell {
    /// The queue every `run(arguments:in:)` call executes on.
    ///
    /// Deliberately a dedicated **serial** queue, not
    /// `DispatchQueue.global()`'s shared concurrent one: `Process.run()`
    /// spawns via `posix_spawn`, which — like `fork()` — is only safe when
    /// no other thread in the process holds a lock (malloc's arena lock,
    /// libdispatch's internal locks, ...) at the moment of the call. Spawning
    /// many `git` subprocesses concurrently from several threads at once,
    /// layered on top of this test suite's *other* concurrently running
    /// subprocess-spawning tests (the LSP daemon/connection tests), was
    /// observed to occasionally wedge the whole test binary. Funneling every
    /// spawn through one serial queue keeps this package's own contribution
    /// to that hazard to "one `git` in flight at a time" without blocking
    /// Swift's cooperative thread pool (the queue itself is a plain OS
    /// thread, bridged back via a continuation) or serializing anything
    /// other than the spawn/wait itself.
    private static let queue = DispatchQueue(label: "com.swissarmyhammer.FoundationModelsCodeContext.git-shell", qos: .utility)

    /// Runs `git <arguments>` in `directory` and returns its captured stdout.
    /// - Parameters:
    ///   - arguments: The `git` subcommand and its arguments (without the leading `"git"` itself).
    ///   - directory: The working directory `git` runs in.
    /// - Returns: The process's captured stdout, decoded as UTF-8 (empty string if undecodable).
    /// - Throws: `CodeContextError.spawnFailed` if the process can't be started or exits non-zero.
    @discardableResult
    static func run(arguments: [String], in directory: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try runBlocking(arguments: arguments, in: directory))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The actual blocking `git` invocation, run only from the background
    /// queue `run(arguments:in:)` dispatches onto.
    private static func runBlocking(arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CodeContextError.spawnFailed("git \(arguments.joined(separator: " ")): \(error.localizedDescription)")
        }

        // Drain stdout before waiting: `waitUntilExit()` first could deadlock
        // if `git`'s output fills the pipe buffer before it exits.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: stderrData, encoding: .utf8) ?? "git \(arguments.joined(separator: " ")) exited \(process.terminationStatus)"
            throw CodeContextError.spawnFailed(message)
        }

        return String(data: stdoutData, encoding: .utf8) ?? ""
    }
}

/// Filesystem glob expansion backing `.file(pattern)` scope resolution.
enum GlobExpansion {
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
        guard pattern.contains(where: { "*?[".contains($0) }) else {
            return [pattern]
        }

        let absolutePattern = pattern.hasPrefix("/") ? pattern : rootDirectory.appendingPathComponent(pattern).path

        var globResult = glob_t()
        defer { globfree(&globResult) }
        guard Darwin.glob(absolutePattern, GLOB_TILDE, nil, &globResult) == 0 else {
            return []
        }
        return (0 ..< Int(globResult.gl_pathc)).compactMap { index in
            globResult.gl_pathv[index].map { String(cString: $0) }
        }
    }
}
