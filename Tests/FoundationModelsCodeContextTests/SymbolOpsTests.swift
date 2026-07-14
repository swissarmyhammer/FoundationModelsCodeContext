import Foundation
import GRDB
import Testing

@testable import FoundationModelsCodeContext

/// Seeds `store` with a chunker-populated Swift fixture file exercising two
/// containers (`MyStruct`, `AuthService`) each with a `new`/second method,
/// plus one free function — the shared fixture `SymbolOpsTests`' `getSymbol`
/// and `searchSymbol` tests match against.
private func seedSymbolFixtures(store: Store, root: URL) async throws {
    try write(
        """
        func main() {}

        struct MyStruct {
            func new() {}
            func authenticate() {}
        }

        struct AuthService {
            func new() {}
            func validate() {}
        }
        """,
        to: "Sample.swift",
        in: root
    )
    _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
    try await TreeSitterWorker.run(store: store, rootDirectory: root)
}

/// Tests for `SymbolOps.getSymbol`/`searchSymbol`/`listSymbols`: the four
/// match tiers (exact > suffix > case-insensitive > fuzzy), the
/// `lsp_symbols` merge/enrichment path, meta-type filtering, and file-scoped
/// listing order — all against a store populated by the real `Chunker` (via
/// `TreeSitterWorker`) on fixtures, per the task's `/tdd` workflow.
struct SymbolOpsTests {
    @Test
    func getSymbolExactMatchOutranksSuffixAndFuzzy() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSymbolFixtures(store: store, root: root)

            let result = try await SymbolOps.getSymbol(store: store, query: "MyStruct.new")

            #expect(result.query == "MyStruct.new")
            #expect(result.symbols.count == 1)
            let match = try #require(result.symbols.first)
            #expect(match.qualifiedPath == "MyStruct.new")
            #expect(match.matchTier == .exact)
            #expect(match.score == 1000)
            #expect(match.source == .treeSitter)
        }
    }

    @Test
    func getSymbolSuffixMatchAcrossContainersWhenNoExactMatch() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSymbolFixtures(store: store, root: root)

            let result = try await SymbolOps.getSymbol(store: store, query: "new")

            #expect(result.symbols.count == 2)
            #expect(result.symbols.allSatisfy { $0.matchTier == .suffix })
            let paths = Set(result.symbols.map(\.qualifiedPath))
            #expect(paths == ["MyStruct.new", "AuthService.new"])
        }
    }

    @Test
    func getSymbolCaseInsensitiveMatchWhenNoExactOrSuffixMatch() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSymbolFixtures(store: store, root: root)

            let result = try await SymbolOps.getSymbol(store: store, query: "MYSTRUCT.NEW")

            #expect(!result.symbols.isEmpty)
            #expect(result.symbols.allSatisfy { $0.matchTier == .caseInsensitive })
            #expect(result.symbols.contains { $0.qualifiedPath == "MyStruct.new" })
        }
    }

    @Test
    func getSymbolFuzzySubsequenceMatchWhenNoOtherTierMatches() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSymbolFixtures(store: store, root: root)

            // "vldt" is not a substring of "AuthService.validate" but is an
            // in-order subsequence (v-a-l-i-d-a-t-e), so only the fuzzy
            // tier can resolve it.
            let result = try await SymbolOps.getSymbol(store: store, query: "vldt")

            #expect(!result.symbols.isEmpty)
            #expect(result.symbols.allSatisfy { $0.matchTier == .fuzzy })
            #expect(result.symbols.contains { $0.qualifiedPath == "AuthService.validate" })
        }
    }

    @Test
    func getSymbolNoMatchReturnsEmptyResult() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSymbolFixtures(store: store, root: root)

            let result = try await SymbolOps.getSymbol(store: store, query: "zzzznonexistent")

            #expect(result.symbols.isEmpty)
        }
    }

    @Test
    func getSymbolMaxResultsCapsSuffixTier() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSymbolFixtures(store: store, root: root)

            let result = try await SymbolOps.getSymbol(store: store, query: "new", maxResults: 1)

            #expect(result.symbols.count == 1)
        }
    }

    @Test
    func getSymbolMergesLspMetadataWithTreeSitterText() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func topLevel() {}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            try await store.write { db in
                try db.execute(sql: """
                INSERT INTO lsp_symbols (id, name, kind, file_path, start_line, start_column, end_line, end_column, detail)
                VALUES (1, 'topLevel', 'function', 'Sample.swift', 0, 5, 0, 14, 'func topLevel() -> Void')
                """)
            }

            let result = try await SymbolOps.getSymbol(store: store, query: "topLevel")

            #expect(result.symbols.count == 1)
            let match = try #require(result.symbols.first)
            #expect(match.source == .merged)
            #expect(match.detail == "func topLevel() -> Void")
            #expect(match.startColumn == 5)
            #expect(match.endColumn == 14)
            #expect(!match.text.isEmpty)
            #expect(match.text.contains("func topLevel"))
        }
    }

    @Test
    func getSymbolIncludesLspOnlySymbolWithEmptyText() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func topLevel() {}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            try await store.write { db in
                try db.execute(sql: """
                INSERT INTO lsp_symbols (id, name, kind, file_path, start_line, start_column, end_line, end_column, detail)
                VALUES (1, 'ghostSymbol', 'variable', 'Sample.swift', 99, 0, 99, 10, NULL)
                """)
            }

            let result = try await SymbolOps.getSymbol(store: store, query: "ghostSymbol")

            #expect(result.symbols.count == 1)
            let match = try #require(result.symbols.first)
            #expect(match.source == .lsp)
            #expect(match.text.isEmpty)
            #expect(match.qualifiedPath == "ghostSymbol")
        }
    }

    @Test
    func getSymbolFuzzyQueryIsCaseInsensitive() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSymbolFixtures(store: store, root: root)

            let result = try await SymbolOps.getSymbol(store: store, query: "VLDT")

            #expect(!result.symbols.isEmpty)
            #expect(result.symbols.allSatisfy { $0.matchTier == .fuzzy })
            #expect(result.symbols.contains { $0.qualifiedPath == "AuthService.validate" })
        }
    }

    @Test
    func getSymbolLspKindNameMappingIsCaseInsensitive() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func topLevel() {}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            try await store.write { db in
                try db.execute(sql: """
                INSERT INTO lsp_symbols (id, name, kind, file_path, start_line, start_column, end_line, end_column, detail)
                VALUES (1, 'topLevel', 'Function', 'Sample.swift', 0, 5, 0, 14, NULL)
                """)
            }

            let result = try await SymbolOps.getSymbol(store: store, query: "topLevel")

            let match = try #require(result.symbols.first)
            #expect(match.kind == .function)
        }
    }

    @Test
    func searchSymbolFuzzyMatchesQualifiedPath() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSymbolFixtures(store: store, root: root)

            let results = try await SymbolOps.searchSymbol(store: store, query: "authenticate")

            #expect(results.contains { $0.qualifiedPath == "MyStruct.authenticate" })
        }
    }

    @Test
    func searchSymbolKindFilterOnlyReturnsMatchingMetaType() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSymbolFixtures(store: store, root: root)

            let results = try await SymbolOps.searchSymbol(store: store, query: "e", kind: .type)

            #expect(!results.isEmpty)
            #expect(results.allSatisfy { $0.kind == .type })
        }
    }

    @Test
    func searchSymbolMaxResultsCaps() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSymbolFixtures(store: store, root: root)

            let results = try await SymbolOps.searchSymbol(store: store, query: "a", maxResults: 2)

            #expect(results.count <= 2)
        }
    }

    @Test
    func searchSymbolNoMatchReturnsEmpty() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSymbolFixtures(store: store, root: root)

            let results = try await SymbolOps.searchSymbol(store: store, query: "zzzznonexistent")

            #expect(results.isEmpty)
        }
    }

    @Test
    func listSymbolsReturnsFileSymbolsInSourceOrder() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSymbolFixtures(store: store, root: root)

            let symbols = try await SymbolOps.listSymbols(store: store, file: "Sample.swift")

            let paths = symbols.map(\.qualifiedPath)
            #expect(paths == [
                "main", "MyStruct", "MyStruct.new", "MyStruct.authenticate",
                "AuthService", "AuthService.new", "AuthService.validate",
            ])
            #expect(symbols.allSatisfy { $0.source == .treeSitter })
        }
    }

    @Test
    func listSymbolsForUnknownFileReturnsEmpty() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSymbolFixtures(store: store, root: root)

            let symbols = try await SymbolOps.listSymbols(store: store, file: "DoesNotExist.swift")

            #expect(symbols.isEmpty)
        }
    }
}

/// Tests for `GrepCode`: regex matching over `ts_chunks.text` with position
/// reporting, language/file-pattern filters, and `maxResults` capping.
struct GrepCodeTests {
    @Test
    func grepCodeFindsMatchesWithBytePositions() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func alpha() {}\nfunc beta() {}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let result = try await GrepCode.run(store: store, pattern: #"func \w+"#)

            #expect(result.pattern == #"func \w+"#)
            #expect(result.matches.count == 2)
            #expect(result.totalChunksSearched == 2)
            #expect(!result.truncated)
            for match in result.matches {
                let position = try #require(match.matches.first)
                let utf8 = match.text.utf8
                let start = utf8.index(utf8.startIndex, offsetBy: position.start)
                let end = utf8.index(utf8.startIndex, offsetBy: position.end)
                #expect(String(decoding: utf8[start..<end], as: UTF8.self).hasPrefix("func"))
            }
        }
    }

    @Test
    func grepCodeMatchPositionsAreUTF8ByteOffsetsNotCharacterOffsets() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            // "café" precedes the match: "é" is 2 UTF-8 bytes but 1
            // Swift `Character`, so a character-offset (rather than a true
            // UTF-8 byte-offset) implementation would misreport the match
            // start by one byte.
            try write("func café() {}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let result = try await GrepCode.run(store: store, pattern: "café")

            #expect(result.matches.count == 1)
            let match = try #require(result.matches.first)
            let position = try #require(match.matches.first)
            let utf8 = match.text.utf8
            let start = utf8.index(utf8.startIndex, offsetBy: position.start)
            let end = utf8.index(utf8.startIndex, offsetBy: position.end)
            #expect(String(decoding: utf8[start..<end], as: UTF8.self) == "café")
            #expect(position.start == 5) // "func " is 5 ASCII bytes
            #expect(position.end == 5 + "café".utf8.count)
        }
    }

    @Test
    func grepCodeLanguageFilterRestrictsToExtension() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func hello() {}\n", to: "Sample.swift", in: root)
            try write("def hello():\n    pass\n", to: "sample.py", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let result = try await GrepCode.run(store: store, pattern: "hello", languages: ["swift"])

            #expect(result.matches.count == 1)
            #expect(result.matches.first?.filePath == "Sample.swift")
            #expect(result.totalChunksSearched == 1)

            // Non-canonical casing ("Swift", not "swift") must still match
            // the (lowercase) file extension — the filter is case-insensitive.
            let uppercasedResult = try await GrepCode.run(store: store, pattern: "hello", languages: ["Swift"])

            #expect(uppercasedResult.matches.count == 1)
            #expect(uppercasedResult.matches.first?.filePath == "Sample.swift")
            #expect(uppercasedResult.totalChunksSearched == 1)
        }
    }

    @Test
    func grepCodeFilePatternFilterRestrictsToGlob() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func hello() {}\n", to: "Sources/Sample.swift", in: root)
            try write("func hello() {}\n", to: "Tests/SampleTests.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let result = try await GrepCode.run(store: store, pattern: "hello", filePattern: "Sources/*")

            #expect(result.matches.count == 1)
            #expect(result.matches.first?.filePath == "Sources/Sample.swift")
        }
    }

    @Test
    func grepCodeMaxResultsCapsAndReportsTruncated() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let source = (0..<5).map { "func func\($0)() {}" }.joined(separator: "\n")
            try write(source, to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let result = try await GrepCode.run(store: store, pattern: #"func \w+"#, maxResults: 2)

            #expect(result.matches.count == 2)
            #expect(result.truncated)
            #expect(result.totalChunksSearched == 5)
        }
    }

    @Test
    func grepCodeInvalidPatternThrowsPatternError() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)

            do {
                _ = try await GrepCode.run(store: store, pattern: "(unclosed")
                Issue.record("expected GrepCode.run to throw for an invalid pattern")
            } catch CodeContextError.pattern {
                // expected
            } catch {
                Issue.record("expected CodeContextError.pattern, got \(error)")
            }
        }
    }

    @Test
    func grepCodeNoMatchesReturnsEmptyResult() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("func hello() {}\n", to: "Sample.swift", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let result = try await GrepCode.run(store: store, pattern: "this_will_never_match_anything")

            #expect(result.matches.isEmpty)
            #expect(!result.truncated)
        }
    }
}
