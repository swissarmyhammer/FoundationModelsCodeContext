import FoundationModelsCodeContext
import Foundation
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

/// Writes `content` to `relativePath` under `root`, creating any missing
/// intermediate directories. Shared across the test target by any suite
/// that needs to materialize fixture files (`ReconcilerTests`, `WalkerTests`).
func write(_ content: String, to relativePath: String, in root: URL) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
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
