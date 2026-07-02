import Foundation
import GRDB

/// Table and column name constants for `kit.db`, shared between the
/// migrations that create the schema (below) and `Store`'s queries against
/// it — one source of truth so the two never drift out of sync.
enum Schema {
    /// One row per file under the workspace root, tracking per-layer
    /// indexing state. See plan.md "The index (SQLite, Rust-derived
    /// schema)".
    enum IndexedFiles {
        static let table = "indexed_files"
        static let filePath = "file_path"
        static let contentHash = "content_hash"
        static let fileSize = "file_size"
        static let lastSeenAt = "last_seen_at"
        static let tsIndexed = "ts_indexed"
        static let lspIndexed = "lsp_indexed"
        static let embedded = "embedded"
    }

    /// Tree-sitter semantic chunks, one row per definition-like node.
    enum TsChunks {
        static let table = "ts_chunks"
        static let id = "id"
        static let filePath = "file_path"
        static let startByte = "start_byte"
        static let endByte = "end_byte"
        static let startLine = "start_line"
        static let endLine = "end_line"
        static let text = "text"
        static let symbolPath = "symbol_path"
        /// The chunk's meta-type (`function | method | type | other`), from
        /// the owning `LanguageModule`'s `chunkKinds` map.
        static let kind = "kind"
        /// Little-endian `Float32` blob (see `EmbeddingCodec`), `NULL`
        /// until the embedding worker processes the chunk.
        static let embedding = "embedding"
    }

    /// Symbols discovered via `textDocument/documentSymbol`, flattened and
    /// qualified.
    enum LspSymbols {
        static let table = "lsp_symbols"
        static let id = "id"
        static let name = "name"
        static let kind = "kind"
        static let filePath = "file_path"
        static let startLine = "start_line"
        static let startColumn = "start_column"
        static let endLine = "end_line"
        static let endColumn = "end_column"
        static let detail = "detail"
    }

    /// Call edges between symbols, from either the LSP call-hierarchy
    /// worker or the tree-sitter heuristic. `file_path` denotes the file
    /// the call site was recorded in (usually the caller's file), so
    /// deleting that file's `indexed_files` row cascades edges away
    /// without a join through `lsp_symbols`.
    enum LspCallEdges {
        static let table = "lsp_call_edges"
        static let id = "id"
        static let callerId = "caller_id"
        static let calleeId = "callee_id"
        static let filePath = "file_path"
        /// JSON-encoded array of source ranges for the call site(s) that
        /// produced this edge.
        static let fromRanges = "from_ranges"
        /// `'lsp'` or `'treesitter'` — which layer discovered this edge.
        static let source = "source"
    }

    /// Small workspace-level key/value table — currently just the embedder
    /// dimension in use, so a dimension change (different embedder/model)
    /// can be detected and trigger re-embedding.
    enum Meta {
        static let table = "meta"
        static let key = "key"
        static let value = "value"
    }
}

/// The GRDB migration set for `kit.db`.
///
/// CodeContextKit owns this schema outright — no cross-implementation
/// compatibility with the Rust sah `index.db` (see plan.md "Index
/// compatibility": resolved, not needed) — so it evolves freely through new
/// migrations appended here.
enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_createSchema") { db in
            try db.create(table: Schema.IndexedFiles.table) { t in
                t.primaryKey(Schema.IndexedFiles.filePath, .text)
                t.column(Schema.IndexedFiles.contentHash, .blob).notNull()
                t.column(Schema.IndexedFiles.fileSize, .integer).notNull()
                t.column(Schema.IndexedFiles.lastSeenAt, .datetime).notNull()
                t.column(Schema.IndexedFiles.tsIndexed, .boolean).notNull().defaults(to: false)
                t.column(Schema.IndexedFiles.lspIndexed, .boolean).notNull().defaults(to: false)
                t.column(Schema.IndexedFiles.embedded, .boolean).notNull().defaults(to: false)
            }

            try db.create(table: Schema.TsChunks.table) { t in
                t.autoIncrementedPrimaryKey(Schema.TsChunks.id)
                t.column(Schema.TsChunks.filePath, .text).notNull()
                    .indexed()
                    .references(Schema.IndexedFiles.table, column: Schema.IndexedFiles.filePath, onDelete: .cascade)
                t.column(Schema.TsChunks.startByte, .integer).notNull()
                t.column(Schema.TsChunks.endByte, .integer).notNull()
                t.column(Schema.TsChunks.startLine, .integer).notNull()
                t.column(Schema.TsChunks.endLine, .integer).notNull()
                t.column(Schema.TsChunks.text, .text).notNull()
                t.column(Schema.TsChunks.symbolPath, .text).notNull()
                t.column(Schema.TsChunks.kind, .text).notNull()
                t.column(Schema.TsChunks.embedding, .blob)
            }

            try db.create(table: Schema.LspSymbols.table) { t in
                t.autoIncrementedPrimaryKey(Schema.LspSymbols.id)
                t.column(Schema.LspSymbols.name, .text).notNull()
                t.column(Schema.LspSymbols.kind, .text).notNull()
                t.column(Schema.LspSymbols.filePath, .text).notNull()
                    .indexed()
                    .references(Schema.IndexedFiles.table, column: Schema.IndexedFiles.filePath, onDelete: .cascade)
                t.column(Schema.LspSymbols.startLine, .integer).notNull()
                t.column(Schema.LspSymbols.startColumn, .integer).notNull()
                t.column(Schema.LspSymbols.endLine, .integer).notNull()
                t.column(Schema.LspSymbols.endColumn, .integer).notNull()
                t.column(Schema.LspSymbols.detail, .text)
            }

            try db.create(table: Schema.LspCallEdges.table) { t in
                t.autoIncrementedPrimaryKey(Schema.LspCallEdges.id)
                t.column(Schema.LspCallEdges.callerId, .integer).notNull()
                    .references(Schema.LspSymbols.table, column: Schema.LspSymbols.id, onDelete: .cascade)
                t.column(Schema.LspCallEdges.calleeId, .integer).notNull()
                    .references(Schema.LspSymbols.table, column: Schema.LspSymbols.id, onDelete: .cascade)
                t.column(Schema.LspCallEdges.filePath, .text).notNull()
                    .indexed()
                    .references(Schema.IndexedFiles.table, column: Schema.IndexedFiles.filePath, onDelete: .cascade)
                t.column(Schema.LspCallEdges.fromRanges, .text).notNull()
                t.column(Schema.LspCallEdges.source, .text).notNull()
                t.check(sql: "\(Schema.LspCallEdges.source) IN ('lsp', 'treesitter')")
            }

            try db.create(table: Schema.Meta.table) { t in
                t.primaryKey(Schema.Meta.key, .text)
                t.column(Schema.Meta.value, .text).notNull()
            }
        }

        return migrator
    }
}
