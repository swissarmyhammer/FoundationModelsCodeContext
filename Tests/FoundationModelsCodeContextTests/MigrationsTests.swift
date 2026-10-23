import Foundation
import GRDB
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `Migrations`: a migration that changes the meaning of rows an
/// index already holds.
struct MigrationsTests {
    @Test
    func theSourceMigrationGivesTheShapeOfASyntheticRowTheTreeSitterSource() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v3_embeddingText")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO indexed_files (file_path, content_hash, file_size, last_seen_at)
                    VALUES ('lib.py', x'00', 1, CURRENT_TIMESTAMP)
                    """)
            // A synthetic row: column 0 at both ends and no detail. A real
            // LSP row: real columns and a detail.
            try db.execute(
                sql: """
                    INSERT INTO lsp_symbols (id, name, kind, file_path, start_line, start_column, end_line, end_column, detail)
                    VALUES (1, 'helper', 'function', 'lib.py', 0, 0, 1, 0, NULL),
                           (2, 'user', 'function', 'lib.py', 4, 4, 5, 20, 'def user()')
                    """)
        }

        try Migrations.migrator.migrate(queue)

        let sources = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT source FROM lsp_symbols ORDER BY id")
        }
        #expect(sources == [Schema.lspSymbolSourceTreeSitter, Schema.lspSymbolSourceLSP])
    }
}
