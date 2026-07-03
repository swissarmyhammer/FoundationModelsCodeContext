import Foundation
import GRDB
import Testing

@testable import CodeContextKit

/// One `lsp_call_edges` row's caller/callee `symbol_path`s and `source`,
/// joined against `lsp_symbols` for readable assertions — the shape every
/// test in this file queries for after running `TreeSitterWorker.run`.
private struct EdgeRow: Equatable {
    let callerSymbolPath: String
    let calleeSymbolPath: String
    let source: String
}

/// Reads every `lsp_call_edges` row for `store`, joined against `lsp_symbols`
/// twice (once for the caller, once for the callee) to recover each side's
/// `name` — the only column `TSCallGraph`'s synthetic `lsp_symbols` rows
/// carry that identifies which symbol an edge's integer ID points at.
private func readEdges(store: Store) async throws -> [EdgeRow] {
    try await store.read { db in
        try Row.fetchAll(
            db,
            sql: """
            SELECT caller.name AS caller_name, callee.name AS callee_name, edges.source AS source
            FROM lsp_call_edges AS edges
            JOIN lsp_symbols AS caller ON caller.id = edges.caller_id
            JOIN lsp_symbols AS callee ON callee.id = edges.callee_id
            ORDER BY caller.name, callee.name
            """
        ).map { row in
            EdgeRow(
                callerSymbolPath: row["caller_name"],
                calleeSymbolPath: row["callee_name"],
                source: row["source"]
            )
        }
    }
}

/// Tests for `TSCallGraph`: edge extraction for swift/rust fixtures (exact
/// and suffix callee resolution), the unresolved-callee and
/// call-outside-any-chunk skip cases, self-recursive-call skipping, and
/// replace-not-duplicate behavior across re-indexing — wired end to end
/// through `TreeSitterWorker.run`, matching this task's `/tdd` workflow.
struct TSCallGraphTests {
    @Test
    func swiftMemberCallResolvesToEdgeWithTreesitterSource() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write(
                """
                struct Helper {
                    static func doWork() {}
                }

                func caller() {
                    Helper.doWork()
                }
                """,
                to: "Sample.swift",
                in: root
            )
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let edges = try await readEdges(store: store)
            #expect(edges == [EdgeRow(callerSymbolPath: "caller", calleeSymbolPath: "doWork", source: "treesitter")])
        }
    }

    @Test
    func rustFreeFunctionCallResolvesToEdgeViaExactMatch() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write(
                """
                fn helper() {}

                fn caller() {
                    helper();
                }
                """,
                to: "sample.rs",
                in: root
            )
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let edges = try await readEdges(store: store)
            #expect(edges == [EdgeRow(callerSymbolPath: "caller", calleeSymbolPath: "helper", source: "treesitter")])
        }
    }

    @Test
    func rustMethodCallResolvesToEdgeViaSuffixMatch() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write(
                """
                struct Widget;

                impl Widget {
                    fn build(&self) {}
                }

                fn caller(widget: &Widget) {
                    widget.build();
                }
                """,
                to: "sample.rs",
                in: root
            )
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let edges = try await readEdges(store: store)
            #expect(edges == [EdgeRow(callerSymbolPath: "caller", calleeSymbolPath: "build", source: "treesitter")])
        }
    }

    @Test
    func unresolvedCalleeProducesNoEdgeAndNoError() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write(
                """
                func caller() {
                    nonexistentFunction()
                }
                """,
                to: "Sample.swift",
                in: root
            )
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let edges = try await readEdges(store: store)
            #expect(edges.isEmpty)
        }
    }

    @Test
    func callOutsideAnyChunkProducesNoEdge() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            // Module-level code isn't wrapped in any chunked node kind
            // (PythonLanguage.chunkKinds only chunks
            // function_definition/class_definition/decorated_definition), so
            // this call to a resolvable callee still has no enclosing
            // ts_chunks row of its own.
            try write(
                """
                def helper():
                    pass

                helper()
                """,
                to: "sample.py",
                in: root
            )
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let edges = try await readEdges(store: store)
            #expect(edges.isEmpty)
        }
    }

    @Test
    func selfRecursiveCallProducesNoEdge() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write(
                """
                fn caller() {
                    caller();
                }
                """,
                to: "sample.rs",
                in: root
            )
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let edges = try await readEdges(store: store)
            #expect(edges.isEmpty)
        }
    }

    @Test
    func underscoreInCalleeNameIsNotTreatedAsSQLWildcard() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            // "Widget.doAWork" is one character away from "Widget.do_Work"
            // at the position the callee's "_" occupies. Before the
            // LIKE-escaping fix, TSCallGraph.resolveCallees built its
            // suffix-match pattern from "do_Work" unescaped, so SQLite
            // treated "_" as a single-character wildcard and this call
            // site incorrectly resolved to "doAWork" (the "_" matching
            // "A"). With "_" escaped, the pattern requires a literal "_"
            // at that position, which "doAWork" doesn't have, so the call
            // site should resolve to nothing.
            try write(
                """
                struct Widget;

                impl Widget {
                    fn doAWork(&self) {}
                }

                fn caller(widget: &Widget) {
                    widget.do_Work();
                }
                """,
                to: "sample.rs",
                in: root
            )
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let edges = try await readEdges(store: store)
            #expect(edges.isEmpty)
        }
    }

    @Test
    func underscoreInCalleeNameStillMatchesLiteralUnderscoreSymbol() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            // The inverse of
            // `underscoreInCalleeNameIsNotTreatedAsSQLWildcard`: escaping
            // "_" in the LIKE pattern must not stop a callee name that
            // genuinely contains "_" from matching a symbol whose name
            // also genuinely contains "_" at that same position.
            try write(
                """
                struct Widget;

                impl Widget {
                    fn do_Work(&self) {}
                }

                fn caller(widget: &Widget) {
                    widget.do_Work();
                }
                """,
                to: "sample.rs",
                in: root
            )
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let edges = try await readEdges(store: store)
            #expect(edges == [EdgeRow(callerSymbolPath: "caller", calleeSymbolPath: "do_Work", source: "treesitter")])
        }
    }

    @Test
    func reindexingReplacesEdgesRatherThanDuplicatingThem() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write(
                """
                func helper() {}

                func caller() {
                    helper()
                }
                """,
                to: "Sample.swift",
                in: root
            )
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let firstRunEdges = try await readEdges(store: store)
            #expect(firstRunEdges == [EdgeRow(callerSymbolPath: "caller", calleeSymbolPath: "helper", source: "treesitter")])

            // Force a second full drain of the same, unchanged file — this
            // exercises TSCallGraph's replace-on-reindex delete, since
            // Reconciler alone wouldn't re-mark an unchanged file dirty.
            _ = try await store.markAllDirty(layer: .treeSitter)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let secondRunEdges = try await readEdges(store: store)
            #expect(secondRunEdges == firstRunEdges)

            let edgeCount = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lsp_call_edges") ?? 0
            }
            #expect(edgeCount == 1)
        }
    }

    @Test
    func lspSourcedEdgesForTheSameFileAreNotDeletedByReindex() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write(
                """
                func helper() {}

                func caller() {
                    helper()
                }
                """,
                to: "Sample.swift",
                in: root
            )
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            // Seed a synthetic LSP-sourced edge for the same file, the way a
            // future LSP indexer worker would. Start lines 500/501 are far
            // past this fixture's real chunks, so they can't collide with
            // TSCallGraph's own (file_path, start_line)-keyed synthetic rows.
            try await store.write { db in
                try db.execute(sql: """
                INSERT INTO lsp_symbols (id, name, kind, file_path, start_line, start_column, end_line, end_column)
                VALUES (1000, 'lspCaller', 'function', 'Sample.swift', 500, 0, 500, 0),
                       (1001, 'lspCallee', 'function', 'Sample.swift', 501, 0, 501, 0)
                """)
                try db.execute(sql: """
                INSERT INTO lsp_call_edges (caller_id, callee_id, file_path, from_ranges, source)
                VALUES (1000, 1001, 'Sample.swift', '[]', 'lsp')
                """)
            }

            _ = try await store.markAllDirty(layer: .treeSitter)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let sources = try await store.read { db in
                try String.fetchAll(db, sql: "SELECT source FROM lsp_call_edges WHERE file_path = 'Sample.swift' ORDER BY source")
            }
            #expect(sources == ["lsp", "treesitter"])
        }
    }
}
