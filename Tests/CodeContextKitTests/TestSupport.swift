import CodeContextKit
import Foundation
import GRDB

/// Creates a fresh temporary workspace directory for `body`, removed
/// afterwards regardless of outcome. Shared across the test target by any
/// suite that needs an isolated on-disk root (`ReconcilerTests`,
/// `WalkerTests`, `StoreTests`).
func withTemporaryWorkspace<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeContextKitTests-\(UUID().uuidString)", isDirectory: true)
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

/// Inserts one `ts_chunks` row (creating its `indexed_files` parent row via
/// `Store.markDirty` first, so the foreign key is satisfied) without going
/// through `TreeSitterWorker`/`Chunker` — lets fixtures pick exact
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
