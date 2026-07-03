import Foundation
import GRDB
import Testing

@testable import CodeContextKit

/// Writes an empty placeholder file at `relativePath` under `root` and
/// records it in `store.rootDirectory`'s `indexed_files` table via
/// `Reconciler.reconcile`, so raw-SQL `lsp_symbols`/`lsp_call_edges` fixture
/// rows inserted afterward satisfy those tables' `file_path` foreign keys —
/// shared by every `CallGraphOpsTests`/`BlastRadiusOpsTests` fixture, none of
/// which need real chunked content, only a real `indexed_files` row per file.
private func seedIndexedFiles(store: Store, root: URL, paths: [String]) async throws {
    for path in paths {
        try write("// fixture\n", to: path, in: root)
    }
    _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
}

/// Inserts one `lsp_symbols` row with the given identity and location.
private func insertSymbol(
    store: Store,
    id: Int64,
    name: String,
    filePath: String,
    startLine: Int = 0,
    startColumn: Int = 0,
    endLine: Int = 10,
    endColumn: Int = 0
) async throws {
    try await store.write { db in
        try db.execute(
            sql: """
            INSERT INTO lsp_symbols (id, name, kind, file_path, start_line, start_column, end_line, end_column)
            VALUES (?, ?, 'function', ?, ?, ?, ?, ?)
            """,
            arguments: [id, name, filePath, startLine, startColumn, endLine, endColumn]
        )
    }
}

/// Inserts one `lsp_call_edges` row from `callerID` to `calleeID`, sourced
/// `"lsp"` unless overridden.
private func insertEdge(store: Store, callerID: Int64, calleeID: Int64, filePath: String, source: String = "lsp") async throws {
    try await store.write { db in
        try db.execute(
            sql: """
            INSERT INTO lsp_call_edges (caller_id, callee_id, file_path, from_ranges, source)
            VALUES (?, ?, ?, '[]', ?)
            """,
            arguments: [callerID, calleeID, filePath, source]
        )
    }
}

/// Seeds an A -> B -> C chain (A calls B, B calls C), each symbol in its own
/// file, all edges sourced `"lsp"` — the shared fixture most
/// `CallGraphOpsTests` cases traverse.
private func seedChain(store: Store, root: URL) async throws {
    try await seedIndexedFiles(store: store, root: root, paths: ["src/a.swift", "src/b.swift", "src/c.swift"])
    try await insertSymbol(store: store, id: 1, name: "func_a", filePath: "src/a.swift")
    try await insertSymbol(store: store, id: 2, name: "func_b", filePath: "src/b.swift")
    try await insertSymbol(store: store, id: 3, name: "func_c", filePath: "src/c.swift")
    try await insertEdge(store: store, callerID: 1, calleeID: 2, filePath: "src/a.swift")
    try await insertEdge(store: store, callerID: 2, calleeID: 3, filePath: "src/b.swift")
}

/// Tests for `CallGraphOps.callGraph(store:of:direction:maxDepth:)`: BFS
/// traversal direction, depth clamping, cycle termination, mixed
/// `lsp`/`treesitter` provenance, and symbol resolution by name or
/// `file:line:char` locator — seeded directly against `lsp_symbols`/
/// `lsp_call_edges`, per the task's `/tdd` workflow.
struct CallGraphOpsTests {
    @Test
    func outboundChainTraversesTwoHopsWithCorrectDepths() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedChain(store: store, root: root)

            let graph = try await CallGraphOps.callGraph(store: store, of: "func_a", direction: .outbound, maxDepth: 2)

            #expect(graph.root.name == "func_a")
            #expect(graph.edges.count == 2)
            #expect(graph.nodes.count == 3)

            let edgeAB = try #require(graph.edges.first { $0.caller.name == "func_a" && $0.callee.name == "func_b" })
            #expect(edgeAB.depth == 1)
            let edgeBC = try #require(graph.edges.first { $0.caller.name == "func_b" && $0.callee.name == "func_c" })
            #expect(edgeBC.depth == 2)
        }
    }

    @Test
    func outboundDepthOneLimitsTraversalToFirstHop() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedChain(store: store, root: root)

            let graph = try await CallGraphOps.callGraph(store: store, of: "func_a", direction: .outbound, maxDepth: 1)

            #expect(graph.edges.count == 1)
            #expect(graph.edges[0].callee.name == "func_b")
        }
    }

    @Test
    func inboundDirectionFollowsCallersNotCallees() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedChain(store: store, root: root)

            let graph = try await CallGraphOps.callGraph(store: store, of: "func_c", direction: .inbound, maxDepth: 2)

            #expect(graph.root.name == "func_c")
            #expect(graph.edges.count == 2)
            #expect(graph.nodes.count == 3)
            #expect(Set(graph.nodes.map(\.name)) == ["func_a", "func_b", "func_c"])
        }
    }

    @Test
    func bothDirectionCombinesInboundAndOutboundAtStart() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedChain(store: store, root: root)

            let graph = try await CallGraphOps.callGraph(store: store, of: "func_b", direction: .both, maxDepth: 1)

            #expect(graph.root.name == "func_b")
            #expect(graph.edges.count == 2)
            #expect(graph.nodes.count == 3)
        }
    }

    @Test
    func bothDirectionOnASelfLoopReportsTheEdgeTwiceButVisitsTheNodeOnce() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedIndexedFiles(store: store, root: root, paths: ["src/s.swift"])
            try await insertSymbol(store: store, id: 1, name: "fn_s", filePath: "src/s.swift")
            // Self-loop: fn_s calls itself.
            try await insertEdge(store: store, callerID: 1, calleeID: 1, filePath: "src/s.swift")

            let graph = try await CallGraphOps.callGraph(store: store, of: "fn_s", direction: .both, maxDepth: 1)

            #expect(graph.nodes.count == 1, "the self-loop's target was already visited, so no new node is added")
            #expect(graph.edges.count == 2, "the self-loop appears once from the outbound query and once from the inbound query")
            #expect(graph.edges.allSatisfy { $0.caller.name == "fn_s" && $0.callee.name == "fn_s" })
        }
    }

    @Test
    func cycleGraphTerminatesAndVisitsEachNodeOnce() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedChain(store: store, root: root)
            // Close the cycle: C -> A.
            try await insertEdge(store: store, callerID: 3, calleeID: 1, filePath: "src/c.swift")

            let graph = try await CallGraphOps.callGraph(store: store, of: "func_a", direction: .outbound, maxDepth: 5)

            #expect(graph.edges.count == 3, "A->B, B->C, C->A, and no repeats past the cycle")
            #expect(graph.nodes.count == 3, "A, B, C each appear exactly once")
            #expect(graph.nodes.map(\.name).sorted() == ["func_a", "func_b", "func_c"])
        }
    }

    @Test
    func maxDepthBelowOneClampsToOne() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedChain(store: store, root: root)

            let graph = try await CallGraphOps.callGraph(store: store, of: "func_a", direction: .outbound, maxDepth: 0)

            #expect(graph.edges.count == 1, "maxDepth 0 clamps to 1, matching outboundDepthOneLimitsTraversalToFirstHop")
        }
    }

    @Test
    func maxDepthAboveFiveClampsToFive() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            // A seven-node chain (six edges) so a clamp to 5 is observable:
            // an unclamped maxDepth of 100 would otherwise return all six.
            let paths = (1...7).map { "src/n\($0).swift" }
            try await seedIndexedFiles(store: store, root: root, paths: paths)
            for index in 1...7 {
                try await insertSymbol(store: store, id: Int64(index), name: "n\(index)", filePath: paths[index - 1])
            }
            for index in 1..<7 {
                try await insertEdge(store: store, callerID: Int64(index), calleeID: Int64(index + 1), filePath: paths[index - 1])
            }

            let graph = try await CallGraphOps.callGraph(store: store, of: "n1", direction: .outbound, maxDepth: 100)

            #expect(graph.edges.count == 5, "maxDepth 100 clamps to 5, so only the first five edges are reachable")
        }
    }

    @Test
    func mixedProvenanceEdgesReportCorrectSource() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedIndexedFiles(store: store, root: root, paths: ["src/x.swift", "src/y.swift", "src/z.swift"])
            try await insertSymbol(store: store, id: 1, name: "fn_x", filePath: "src/x.swift")
            try await insertSymbol(store: store, id: 2, name: "fn_y", filePath: "src/y.swift")
            try await insertSymbol(store: store, id: 3, name: "fn_z", filePath: "src/z.swift")
            try await insertEdge(store: store, callerID: 1, calleeID: 2, filePath: "src/x.swift", source: "lsp")
            try await insertEdge(store: store, callerID: 1, calleeID: 3, filePath: "src/x.swift", source: "treesitter")

            let graph = try await CallGraphOps.callGraph(store: store, of: "fn_x", direction: .outbound, maxDepth: 1)

            #expect(graph.edges.count == 2)
            let lspEdge = try #require(graph.edges.first { $0.callee.name == "fn_y" })
            #expect(lspEdge.source == .lsp)
            let treeSitterEdge = try #require(graph.edges.first { $0.callee.name == "fn_z" })
            #expect(treeSitterEdge.source == .treeSitter)
        }
    }

    @Test
    func noEdgesReturnsRootOnlyGraph() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedIndexedFiles(store: store, root: root, paths: ["src/lonely.swift"])
            try await insertSymbol(store: store, id: 1, name: "lonely", filePath: "src/lonely.swift")

            let graph = try await CallGraphOps.callGraph(store: store, of: "lonely", direction: .outbound, maxDepth: 2)

            #expect(graph.root.name == "lonely")
            #expect(graph.edges.isEmpty)
            #expect(graph.nodes.count == 1)
        }
    }

    @Test
    func symbolNotFoundThrowsNotFoundError() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)

            do {
                _ = try await CallGraphOps.callGraph(store: store, of: "nonexistent", direction: .outbound, maxDepth: 2)
                Issue.record("expected callGraph to throw for an unresolvable symbol")
            } catch CodeContextError.notFound(let message) {
                #expect(message.contains("nonexistent"))
            } catch {
                Issue.record("expected CodeContextError.notFound, got \(error)")
            }
        }
    }

    @Test
    func resolvesRootByFileLineCharLocator() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedIndexedFiles(store: store, root: root, paths: ["src/main.swift"])
            try await insertSymbol(store: store, id: 1, name: "process", filePath: "src/main.swift", startLine: 10, startColumn: 0, endLine: 20, endColumn: 50)

            let graph = try await CallGraphOps.callGraph(store: store, of: "src/main.swift:15:5", direction: .outbound, maxDepth: 1)

            #expect(graph.root.name == "process")
            #expect(graph.root.filePath == "src/main.swift")
        }
    }

    @Test
    func locationLocatorResolvesToNarrowestEnclosingSymbol() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedIndexedFiles(store: store, root: root, paths: ["src/lib.swift"])
            // Outer symbol spans lines 5..30.
            try await insertSymbol(store: store, id: 1, name: "MyStructImpl", filePath: "src/lib.swift", startLine: 5, startColumn: 0, endLine: 30, endColumn: 0)
            // Inner symbol spans lines 10..15 -- narrower.
            try await insertSymbol(store: store, id: 2, name: "new", filePath: "src/lib.swift", startLine: 10, startColumn: 0, endLine: 15, endColumn: 40)

            let graph = try await CallGraphOps.callGraph(store: store, of: "src/lib.swift:12:5", direction: .outbound, maxDepth: 1)

            #expect(graph.root.name == "new", "should resolve to the narrowest enclosing symbol")
        }
    }
}

/// Tests for `BlastRadiusOps.blastRadius(store:file:symbol:maxHops:)`:
/// inbound BFS aggregation per hop, same-file dedup within and across hops,
/// `maxHops` clamping, and the whole-file-vs-named-symbol not-found
/// distinction — seeded directly against `lsp_symbols`/`lsp_call_edges`, per
/// the task's `/tdd` workflow.
struct BlastRadiusOpsTests {
    @Test
    func singleHopBlastRadiusReturnsDirectCallers() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedChain(store: store, root: root)

            let radius = try await BlastRadiusOps.blastRadius(store: store, file: "src/c.swift", symbol: "func_c", maxHops: 1)

            #expect(radius.hops.count == 1)
            #expect(radius.hops[0].hop == 1)
            #expect(radius.hops[0].symbols.map(\.name) == ["func_b"])
            #expect(radius.totalAffectedSymbols == 1)
            #expect(radius.totalAffectedFiles == 1)
        }
    }

    @Test
    func twoHopBlastRadiusAggregatesAcrossHops() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedChain(store: store, root: root)

            let radius = try await BlastRadiusOps.blastRadius(store: store, file: "src/c.swift", symbol: "func_c", maxHops: 2)

            #expect(radius.hops.count == 2)
            #expect(radius.hops[0].hop == 1)
            #expect(radius.hops[0].symbols.map(\.name) == ["func_b"])
            #expect(radius.hops[1].hop == 2)
            #expect(radius.hops[1].symbols.map(\.name) == ["func_a"])
            #expect(radius.totalAffectedSymbols == 2)
            #expect(radius.totalAffectedFiles == 2)
        }
    }

    @Test
    func wholeFileWithoutSymbolFilterUsesEveryFileSymbolAsARoot() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedChain(store: store, root: root)

            let radius = try await BlastRadiusOps.blastRadius(store: store, file: "src/c.swift", symbol: nil, maxHops: 3)

            #expect(radius.hops.count == 2)
            #expect(radius.totalAffectedSymbols == 2)
        }
    }

    @Test
    func noCallersReturnsEmptyHopsWithoutError() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedChain(store: store, root: root)

            let radius = try await BlastRadiusOps.blastRadius(store: store, file: "src/a.swift", symbol: "func_a", maxHops: 5)

            #expect(radius.hops.isEmpty)
            #expect(radius.totalAffectedSymbols == 0)
            #expect(radius.totalAffectedFiles == 0)
        }
    }

    @Test
    func mixedProvenanceHopReportsSourcePerSymbol() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedIndexedFiles(store: store, root: root, paths: ["src/x.swift", "src/y.swift", "src/z.swift"])
            try await insertSymbol(store: store, id: 1, name: "fn_x", filePath: "src/x.swift")
            try await insertSymbol(store: store, id: 2, name: "fn_y", filePath: "src/y.swift")
            try await insertSymbol(store: store, id: 3, name: "fn_z", filePath: "src/z.swift")
            try await insertEdge(store: store, callerID: 2, calleeID: 1, filePath: "src/y.swift", source: "lsp")
            try await insertEdge(store: store, callerID: 3, calleeID: 1, filePath: "src/z.swift", source: "treesitter")

            let radius = try await BlastRadiusOps.blastRadius(store: store, file: "src/x.swift", symbol: "fn_x", maxHops: 1)

            #expect(radius.hops.count == 1)
            #expect(radius.hops[0].symbols.count == 2)
            let lspSymbol = try #require(radius.hops[0].symbols.first { $0.name == "fn_y" })
            #expect(lspSymbol.source == .lsp)
            let treeSitterSymbol = try #require(radius.hops[0].symbols.first { $0.name == "fn_z" })
            #expect(treeSitterSymbol.source == .treeSitter)
        }
    }

    @Test
    func namedSymbolNotFoundInFileThrowsNotFoundError() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedChain(store: store, root: root)

            do {
                _ = try await BlastRadiusOps.blastRadius(store: store, file: "src/a.swift", symbol: "nonexistent", maxHops: 3)
                Issue.record("expected blastRadius to throw for a named symbol missing from the file")
            } catch CodeContextError.notFound(let message) {
                #expect(message.contains("nonexistent"))
                #expect(message.contains("src/a.swift"))
            } catch {
                Issue.record("expected CodeContextError.notFound, got \(error)")
            }
        }
    }

    @Test
    func wholeFileWithNoIndexedSymbolsIsEmptyNotAnError() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedIndexedFiles(store: store, root: root, paths: ["src/empty.swift"])

            let radius = try await BlastRadiusOps.blastRadius(store: store, file: "src/empty.swift", symbol: nil, maxHops: 3)

            #expect(radius.roots.isEmpty)
            #expect(radius.hops.isEmpty)
            #expect(radius.totalAffectedSymbols == 0)
            #expect(radius.totalAffectedFiles == 0)
        }
    }

    @Test
    func maxHopsAboveTenClampsToTen() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            // A twelve-node inbound chain (n12 <- n11 <- ... <- n1) so a
            // clamp to 10 hops is observable from n12's blast radius.
            let paths = (1...12).map { "src/n\($0).swift" }
            try await seedIndexedFiles(store: store, root: root, paths: paths)
            for index in 1...12 {
                try await insertSymbol(store: store, id: Int64(index), name: "n\(index)", filePath: paths[index - 1])
            }
            for index in 1..<12 {
                try await insertEdge(store: store, callerID: Int64(index), calleeID: Int64(index + 1), filePath: paths[index - 1])
            }

            let radius = try await BlastRadiusOps.blastRadius(store: store, file: "src/n12.swift", symbol: "n12", maxHops: 100)

            #expect(radius.hops.count == 10, "maxHops 100 clamps to 10")
        }
    }

    @Test
    func hopAggregationDedupsAffectedFilesWithinAndAcrossHops() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            // Root R in target.swift; two hop-1 callers (X1, X2) both live in
            // caller.swift, so that file must count once, not twice, in
            // hop 1's affectedFiles. A hop-2 caller Y lives in a third file,
            // so the running total across hops must still count caller.swift
            // only once even though it appears at hop 1.
            try await seedIndexedFiles(store: store, root: root, paths: ["src/target.swift", "src/caller.swift", "src/y.swift"])
            try await insertSymbol(store: store, id: 1, name: "root", filePath: "src/target.swift")
            try await insertSymbol(store: store, id: 2, name: "x1", filePath: "src/caller.swift", startLine: 0, endLine: 5)
            try await insertSymbol(store: store, id: 3, name: "x2", filePath: "src/caller.swift", startLine: 6, endLine: 10)
            try await insertSymbol(store: store, id: 4, name: "y", filePath: "src/y.swift")
            try await insertEdge(store: store, callerID: 2, calleeID: 1, filePath: "src/caller.swift")
            try await insertEdge(store: store, callerID: 3, calleeID: 1, filePath: "src/caller.swift")
            try await insertEdge(store: store, callerID: 4, calleeID: 2, filePath: "src/y.swift")

            let radius = try await BlastRadiusOps.blastRadius(store: store, file: "src/target.swift", symbol: "root", maxHops: 3)

            #expect(radius.hops.count == 2)
            #expect(radius.hops[0].symbols.count == 2, "both x1 and x2 are hop-1 callers of root")
            #expect(radius.hops[0].affectedFiles == 1, "x1 and x2 share caller.swift, so it counts once at hop 1")
            #expect(radius.hops[1].symbols.map(\.name) == ["y"])
            #expect(radius.totalAffectedFiles == 2, "caller.swift and y.swift, each counted once across all hops")
        }
    }
}
