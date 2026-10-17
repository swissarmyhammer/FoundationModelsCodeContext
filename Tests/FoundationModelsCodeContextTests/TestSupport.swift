import Foundation
import FoundationModelsCodeContext
import FoundationModelsExtras
import GRDB

/// Creates a fresh temporary workspace directory for `body`, removed
/// afterwards regardless of outcome. Shared across the test target by any
/// suite that needs an isolated on-disk root (`ReconcilerTests`,
/// `WalkerTests`, `StoreTests`).
func withTemporaryWorkspace<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FoundationModelsCodeContextTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
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
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("FoundationModelsCodeContextTests-link-\(UUID().uuidString)", isDirectory: true)
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

/// Writes `content` to `relativePath` under `root`, creating any missing
/// intermediate directories. Shared across the test target by any suite
/// that needs to materialize fixture files (`ReconcilerTests`, `WalkerTests`).
func write(_ content: String, to relativePath: String, in root: URL) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
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
    /// Encodes `value` with `.sortedKeys` and returns the JSON text.
    ///
    /// The tools encode each result with `.sortedKeys`, so this text is the
    /// same as the output of a tool for the same value.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: The JSON text.
    /// - Throws: An `EncodingError` when `value` cannot be encoded.
    static func encodedText<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
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
