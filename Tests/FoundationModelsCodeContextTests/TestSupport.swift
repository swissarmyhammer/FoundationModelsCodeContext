import Foundation
@testable import FoundationModelsCodeContext
import FoundationModelsExtras
import GRDB
import Testing

/// The place of each temporary item of the test target.
///
/// Each item is below one shared directory in `/tmp`, not below `$TMPDIR`.
/// Many processes of the user write in `$TMPDIR`. When `$TMPDIR` holds very
/// many entries (one machine had about one million), each change of
/// `$TMPDIR` is slow and locks it, and each path lookup through `$TMPDIR`
/// waits for the lock: one `mkdir`, `rmdir`, `lstat` or `realpath(3)` can take
/// seconds. The code under test calls `realpath(3)` on the workspace root,
/// and SQLite calls `lstat` on each component of the path of the database.
/// Each blocked call holds one thread of the cooperative pool. The tests run
/// in parallel, thus all the threads can block, the whole test process stops
/// for about a minute, and the tests that measure time fail. Below `/tmp`,
/// the same calls take milliseconds.
///
/// The directory is not below the package directory, because a workspace
/// there is inside the git work tree of the package, and the tests that
/// expect a workspace that is not a git repository then fail.
enum TemporaryItem {
    /// The directory that holds the shared directory.
    private static let parent = URL(fileURLWithPath: "/tmp", isDirectory: true)

    /// The shared directory, `/tmp/FoundationModelsCodeContextTests-<uid>`.
    ///
    /// The user ID is in the name, because a different user cannot write in
    /// a directory of this user. The name is fixed for one user, thus each
    /// test run uses the same directory and adds no entry to `/tmp`. The
    /// tests do not remove this directory, because a different test run can
    /// use it at the same time. The first item that a test creates with
    /// `withIntermediateDirectories: true` also creates this directory.
    static let root = parent.appendingPathComponent("FoundationModelsCodeContextTests-\(getuid())", isDirectory: true)

    /// The fixed subfolder of `root` that holds the joined script files of
    /// `ScriptedLSPServerScript.path(in:)`.
    ///
    /// The script file is a cache: each test and each test run use the same
    /// file again, thus the folder has a fixed name. The folder keeps the
    /// cache out of `root` itself, because no test writes directly into
    /// `root`.
    static let scriptedLSPServerDirectory = root.appendingPathComponent("scripted-lsp-server", isDirectory: true)

    /// Gives a new, unique URL below `root`. No item exists at the URL.
    ///
    /// Create the item with `withIntermediateDirectories: true`, because
    /// `root` possibly does not exist yet.
    /// - Parameter prefix: The start of the last path component. It tells
    ///   the use of the item.
    /// - Returns: The URL `root/<prefix>-<UUID>`.
    static func makeURL(prefix: String) -> URL {
        root.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}

/// Creates a fresh temporary workspace directory for `body`, removed
/// afterwards regardless of outcome. Shared across the test target by any
/// suite that needs an isolated on-disk root (`ReconcilerTests`,
/// `WalkerTests`, `StoreTests`). The directory is below `TemporaryItem.root`.
func withTemporaryWorkspace<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = TemporaryItem.makeURL(prefix: "workspace")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

extension TemporaryItem {
    /// The name of the workspace root in its private parent directory.
    private static let nestedWorkspaceName = "workspace"

    /// Creates a workspace root for `body` one level below a new private
    /// directory, and removes both after `body` on each exit path.
    ///
    /// Use this when a test writes a file outside the root, for example
    /// `../secret.swift`. The parent of a root from `withTemporaryWorkspace`
    /// is `TemporaryItem.root`, which all tests share and which no test
    /// removes. The parent of this root is a directory of this test only,
    /// thus a file that the test writes in it goes away with the directory,
    /// and two parallel tests never write the same file.
    /// - Parameter body: The work. It gets the workspace root.
    /// - Returns: `body`'s result.
    /// - Throws: Rethrows what `body` throws, or the error of the creation of
    ///   a directory.
    static func withNestedWorkspace<T>(_ body: (URL) async throws -> T) async throws -> T {
        try await withTemporaryWorkspace { parent in
            let root = parent.appendingPathComponent(nestedWorkspaceName, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return try await body(root)
        }
    }
}

/// The POSIX mode `-wx------` of a directory: write and search, no read.
///
/// A walk cannot list a directory with this mode, but a path below the
/// directory still opens. A test gives this mode to a workspace root to make
/// the walk fail while the database files of the store stay reachable.
let unlistableDirectoryPermissions = 0o300

/// The POSIX mode `---------`: no read, no write and no search.
let noAccessPermissions = 0o000

/// The POSIX mode `rwxr-xr-x` that a test gives back to a directory.
let restoredDirectoryPermissions = 0o755

/// The POSIX mode `rw-r--r--` that a test gives back to a file.
let restoredFilePermissions = 0o644

/// Gives `permissions` to the item at `url` for the time of `body`, and then
/// gives `restoredPermissions` to the item on each exit path.
///
/// The tests use this to make an item that the walk cannot examine. The
/// restore lets `withTemporaryWorkspace` remove the item.
/// - Parameters:
///   - permissions: The POSIX mode that the item has while `body` runs.
///   - url: The file or directory.
///   - restoredPermissions: The POSIX mode that the item gets after `body`.
///   - body: The work.
/// - Returns: `body`'s result.
/// - Throws: Rethrows what `body` throws, or the error of the first change of
///   the mode.
func withPermissions<T>(
    _ permissions: Int,
    at url: URL,
    restoringTo restoredPermissions: Int,
    _ body: () async throws -> T
) async throws -> T {
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: restoredPermissions], ofItemAtPath: url.path) }
    return try await body()
}

/// Creates a temporary workspace for `body` and gives `body` a symbolic link
/// to it as the root. Both are removed afterwards.
///
/// The watcher tests and the reconcile tests use this to examine a root that
/// is a symbolic link: FSEvents then sends the real path of a file, not the
/// path through the link.
/// - Parameter body: The work. It gets the link (the root of the workspace)
///   and the real directory that the link points to.
/// - Returns: `body`'s result.
/// - Throws: Rethrows what `body` throws, or the error of the link creation.
func withSymlinkedWorkspace<T>(_ body: (_ link: URL, _ target: URL) async throws -> T) async throws -> T {
    try await withTemporaryWorkspace { target in
        let link = TemporaryItem.makeURL(prefix: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: link) }
        return try await body(link, target)
    }
}

/// Gives the real path of `url` from `realpath(3)`: each symbolic link is
/// resolved, and the `/private` prefix of `/var` and `/tmp` stays.
///
/// `URL.resolvingSymlinksInPath()` removes the `/private` prefix, thus it does
/// not give the path that FSEvents sends.
/// - Parameter url: A file URL of an item that exists.
/// - Returns: The real path as a file URL.
/// - Throws: `CocoaError(.fileNoSuchFile)` when `realpath(3)` fails.
func realPath(of url: URL) throws -> URL {
    let resolved = url.path.withCString { pointer -> String? in
        guard let buffer = realpath(pointer, nil) else {
            return nil
        }
        defer { free(buffer) }
        return String(cString: buffer)
    }
    guard let resolved else {
        throw CocoaError(.fileNoSuchFile)
    }
    return URL(fileURLWithPath: resolved)
}

/// Runs `body`, and then runs `cleanup` on every exit path (success or
/// throw). Use it to open a gate, stop a context or await a task that a test
/// starts, so that nothing that the test starts outlives the test.
///
/// A `defer` block cannot `await`, thus this helper does the same work for
/// an `async` cleanup. The integration package has the same helper, because
/// that package cannot import this test target.
/// - Parameters:
///   - body: The work.
///   - cleanup: The work that always runs after `body`.
/// - Returns: `body`'s result.
/// - Throws: Rethrows whatever `body` throws, after `cleanup` has run.
func withAsyncCleanup<T>(
    _ body: () async throws -> T,
    cleanup: () async -> Void
) async throws -> T {
    do {
        let result = try await body()
        await cleanup()
        return result
    } catch {
        await cleanup()
        throw error
    }
}

/// The real time between two checks of `waitUntil(timeout:pollInterval:_:)`
/// when the caller gives no interval.
let defaultWaitPollInterval: Duration = .milliseconds(1)

/// Checks `isDone` again and again until it returns `true`. Between two
/// checks, the wait sleeps for `pollInterval` of real time.
///
/// This is the one polling wait of the test target. A test uses it when the
/// work that it waits for runs in a task that the test cannot await, for
/// example a restart of a daemon, a step of an install, or an index pass of a
/// context. The integration package has its own `poll(budget:interval:until:)`,
/// because that package cannot import this test target.
///
/// `timeout` is the one difference between the callers:
/// - With a `timeout`, the wait returns `false` when the time elapses before
///   `isDone` returns `true`. The caller then makes its own assertion, which
///   tells what did not occur.
/// - With no `timeout`, the wait continues until `isDone` returns `true`. The
///   time limit of the test stops a wait that cannot end.
///
/// The wait always throws when its task is cancelled. A wait that ignores the
/// cancellation does not sleep any more (`Task.sleep` returns at once in a
/// cancelled task), thus it checks `isDone` with no pause until its timeout,
/// or for ever when it has no timeout.
/// - Parameters:
///   - timeout: The longest time to wait, or `nil` for no limit.
///   - pollInterval: The real time between two checks.
///   - isDone: Returns `true` when the state that the test waits for is
///     present.
/// - Returns: `true` when `isDone` returned `true`, `false` when `timeout`
///   elapsed first.
/// - Throws: `CancellationError` when the task is cancelled, or the error that
///   `isDone` throws.
@discardableResult
func waitUntil(
    timeout: Duration? = nil,
    pollInterval: Duration = defaultWaitPollInterval,
    _ isDone: () async throws -> Bool
) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = timeout.map { clock.now.advanced(by: $0) }
    while try await !isDone() {
        if let deadline, clock.now >= deadline {
            return false
        }
        try await Task.sleep(for: pollInterval)
    }
    return true
}

/// The time limit of each test that uses a `.timeLimit` trait, in minutes. A
/// test that does not end, for example a `start()` or a `stop()` that waits
/// for a closed gate, fails at this limit. All suites read this one value.
let testTimeLimitMinutes = 1

/// The number of seconds in `readyAfterInstallTimeout`.
let readyAfterInstallTimeoutSeconds = 5

/// The longest real time that a test waits for `isReady` after a failed
/// auto-install. The forced restart after the install gives `.notFound` again
/// in some milliseconds. All suites read this one value.
let readyAfterInstallTimeout: Duration = .seconds(readyAfterInstallTimeoutSeconds)

/// Writes `content` to `relativePath` under `root`, creating any missing
/// intermediate directories. Shared across the test target by any suite
/// that needs to materialize fixture files (`ReconcilerTests`, `WalkerTests`).
func write(_ content: String, to relativePath: String, in root: URL) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
}

/// Writes `content` to a file in `outside`, and makes a symbolic link to that
/// file at `linkPath` below `root`. The link is in the root, but its target is
/// not.
/// - Parameters:
///   - content: The text of the target file.
///   - linkPath: The path of the link, relative to `root`.
///   - root: The workspace root.
///   - outside: A directory that is not below `root`.
/// - Throws: The error of the write or of the link creation.
func writeLinkOutOfRoot(_ content: String, at linkPath: String, in root: URL, outside: URL) throws {
    let targetName = "outside-\(UUID().uuidString).swift"
    try write(content, to: targetName, in: outside)
    let link = root.appendingPathComponent(linkPath)
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.appendingPathComponent(targetName))
}

/// A workspace tree that holds each kind of ignore rule: a root `.gitignore`
/// with a directory rule, an anchored rule and a negation, a nested
/// `.gitignore`, an `.ignore` file, a `.git/info/exclude` file, the hard skip
/// directories and a hidden directory.
///
/// `WalkerTests` and `WatcherTests` write this tree, so the walker and the
/// watcher examine the same paths.
enum IgnoreRulesTree {
    /// Each source file of the tree, relative to the root. Each file has an
    /// extension that the index reads.
    static let sourceFiles = [
        "kept.rs",
        "src/a.swift",
        "src/b.tmp.swift",
        "src/dist/e.rs",
        "dist/d.rs",
        "generated/g.rs",
        "x.log.rs",
        "keep.log.rs",
        "build-out/a/b.swift",
        "scratch/s.rs",
        "local-only.rs",
        "target/debug/t.rs",
        "node_modules/m/i.ts",
        ".hidden/h.rs",
        ".build/b.rs",
    ]

    /// The files of `sourceFiles` that no rule ignores.
    static let keptFiles: Set<String> = ["kept.rs", "src/a.swift", "src/dist/e.rs", "keep.log.rs"]

    /// Writes the rule files and each file of `sourceFiles` under `root`.
    /// - Parameter root: The workspace root.
    /// - Throws: The error of a write.
    static func write(in root: URL) throws {
        try FoundationModelsCodeContextTests.write("generated/\n*.log.rs\n!keep.log.rs\nbuild-out/\n/dist\n", to: ".gitignore", in: root)
        try FoundationModelsCodeContextTests.write("*.tmp.swift\n", to: "src/.gitignore", in: root)
        try FoundationModelsCodeContextTests.write("scratch/\n", to: ".ignore", in: root)
        try FoundationModelsCodeContextTests.write("local-only.rs\n", to: ".git/info/exclude", in: root)
        for path in sourceFiles {
            try FoundationModelsCodeContextTests.write("// \(path)\n", to: path, in: root)
        }
    }
}

/// Writes a tree with the markers of a Django checkout and Python sources
/// only: a `pyproject.toml` and two modules, a `package.json` at the root
/// (Django has one for the JavaScript tests of the admin) and a
/// `docs/Makefile` (Django builds its docs with one). The tree has no C,
/// C++, TypeScript or JavaScript file. Shared by `ProjectDetectionTests`
/// and `LspSupervisorTests`.
/// - Parameter root: The workspace root to write the tree into.
func writeMostlyPythonTree(in root: URL) throws {
    try write("[project]\nname = \"site\"\nversion = \"0.1.0\"\n", to: "pyproject.toml", in: root)
    try write("def helper():\n    return 1\n", to: "site/helpers.py", in: root)
    try write("from site.helpers import helper\n\n\ndef main():\n    return helper()\n", to: "site/main.py", in: root)
    try write("{\"name\": \"site\", \"private\": true}\n", to: "package.json", in: root)
    try write("html:\n\tsphinx-build -b html . _build\n", to: "docs/Makefile", in: root)
}

/// A `PooledEmbedding` that the caller defines, with no model and no network.
///
/// The public-API test suites use this type. Those suites see only the public
/// API, so they cannot use the internal `FakeEmbedder`. The first entry of
/// each vector is the character count of its text, and the other entries are
/// zero. The vectors are not useful for search; the suites examine only that
/// the public API accepts the type.
struct CallerDefinedEmbedder: PooledEmbedding {
    /// The length of each vector that `embed(texts:)` returns.
    let vectorLength: Int

    /// Returns one `vectorLength`-length vector for each text, in order.
    ///
    /// - Parameter texts: The texts to embed.
    /// - Returns: One vector for each text, in the order of `texts`.
    func embed(texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            [Float(text.count)] + Array(repeating: 0, count: vectorLength - 1)
        }
    }
}

/// The JSON helpers of the test target.
enum TestJSON {
    /// The JSON-RPC 2.0 error code `MethodNotFound`, as the specification gives it. The tests
    /// compare the replies of the client with this value, not with the constant of the package.
    static let methodNotFoundCode = -32601

    /// Encodes `value` as a tool gives it and returns the JSON text: with
    /// `.sortedKeys`, and with each line and each column from 1.
    ///
    /// The tools encode each result with `.sortedKeys`, through
    /// `ToolOutcome`, so this text is the same as the output of a tool for the
    /// same engine result.
    ///
    /// - Parameter value: The engine result.
    /// - Returns: The JSON text.
    /// - Throws: An `EncodingError` when `value` cannot be encoded.
    static func encodedText<Value: Encodable & Sendable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(ToolOutcome.success(value)), as: UTF8.self)
    }

    /// Encodes `value` as a tool gives it, and parses the JSON object again.
    ///
    /// - Parameter value: The engine result. It must encode as a JSON object.
    /// - Returns: The parsed JSON object, with each line and each column from 1.
    /// - Throws: An `EncodingError` when `value` cannot be encoded, or an
    ///   expectation failure when the JSON is not an object.
    static func toolObject<Value: Encodable & Sendable>(_ value: Value) throws -> NSDictionary {
        try encodedObject(ToolOutcome.success(value))
    }

    /// Encodes `value` and parses the JSON object again.
    ///
    /// The result is an `NSDictionary`, thus a test can read a nested value with
    /// `value(forKeyPath:)`.
    ///
    /// - Parameter value: The value to encode. It must encode as a JSON object.
    /// - Returns: The parsed JSON object.
    /// - Throws: An `EncodingError` when `value` cannot be encoded, or an
    ///   expectation failure when the JSON is not an object.
    static func encodedObject<Value: Encodable>(_ value: Value) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(value)) as? NSDictionary)
    }
}

/// Builds a Swift function named `deepSpine` whose body is
/// `leadingStatements` followed by a single `1 + 1 + …` expression of
/// `termCount` terms.
///
/// Every grammar parses a chained binary operator into a left-nested spine one
/// node deep per term, which makes this the cheapest way to produce an AST far
/// deeper than any real source file — the input the recursive tree-sitter
/// walks' depth bound exists to survive. `leadingStatements` is written
/// verbatim ahead of the expression, already indented by the caller, for a
/// suite that needs something shallow inside the same pathological function
/// (a call site, say) to assert the bound still reports what sits above it.
/// Shared across the test target by every suite that exercises that bound
/// (`ChunkerTests`, `TSCallGraphTests`, `ComplexityTests`).
func swiftDeepExpressionSpine(termCount: Int, leadingStatements: String = "") -> String {
    "func deepSpine() -> Int {\n"
        + leadingStatements
        + "    return 1"
        + String(repeating: " + 1", count: termCount - 1)
        + "\n}\n"
}

/// Builds a Swift function whose body is `count` `if` statements nested one
/// inside the next, with a second definition at the very bottom of the nest.
///
/// Ordinary-shaped code, for pinning down that the recursive tree-sitter
/// walks' depth bound leaves real source alone: 50 levels of `if` parse 106
/// AST levels deep, comfortably under `Chunker.maxASTDepth`, so both the
/// branching depth and the innermost definition must still be reported in
/// full. Shared across the test target by every suite that exercises that
/// bound (`ChunkerTests`, `ComplexityTests`).
func swiftNestedIfs(count: Int) -> String {
    var body = ""
    for level in 0..<count {
        body += String(repeating: "    ", count: level + 1) + "if flag\(level) {\n"
    }
    body += String(repeating: "    ", count: count + 1) + "func innermost() {}\n"
    for level in stride(from: count - 1, through: 0, by: -1) {
        body += String(repeating: "    ", count: level + 1) + "}\n"
    }
    return "func deeplyNested() {\n" + body + "}\n"
}

/// Inserts a test fixture chunk with precise control over symbol path, kind, and embedding values.
///
/// Creates the `indexed_files` parent row via `Store.markDirty` first, so
/// the foreign key is satisfied, then inserts the `ts_chunks` row directly
/// — bypassing `TreeSitterWorker`/`Chunker` so fixtures can pick exact
/// `symbolPath`/`kind`/`text`/`embedding` values. Shared across the test
/// target by any suite that needs precise control over chunk fixtures
/// (`SearchCodeTests`, `FindDuplicatesTests`).
func insertChunk(
    store: Store,
    filePath: String,
    symbolPath: String,
    text: String,
    kind: SymbolMetaType = .function,
    startLine: Int = 0,
    endLine: Int = 1,
    embedding: [Float]? = nil
) async throws {
    try await store.markDirty(filePath: filePath, contentHash: Data(filePath.utf8), fileSize: Int64(text.utf8.count))
    try await store.write { db in
        try db.execute(
            sql: """
                INSERT INTO ts_chunks (file_path, start_byte, end_byte, start_line, end_line, text, symbol_path, kind, embedding)
                VALUES (?, 0, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                filePath, text.utf8.count, startLine, endLine, text, symbolPath, kind.rawValue,
                embedding.map(EmbeddingCodec.encode),
            ]
        )
    }
}
