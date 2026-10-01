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
    /// How many more times `searchSymbolGivesTiedMatchesTheSameOrderOnEveryCall`
    /// repeats its query to show that the order of the tied matches does not
    /// change from one call to the next.
    private static let repeatedCallCount = 20

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
                try db.execute(
                    sql: """
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
                try db.execute(
                    sql: """
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
                try db.execute(
                    sql: """
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
    func searchSymbolGivesTiedMatchesTheSameOrderOnEveryCall() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write(
                """
                struct Greeter {
                    func greet() -> String {
                        return helper()
                    }
                }

                func helper() -> String {
                    "hello"
                }
                """,
                to: "Greeter.swift",
                in: root
            )
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            try await TreeSitterWorker.run(store: store, rootDirectory: root)

            let first = try await SymbolOps.searchSymbol(store: store, query: "greet")

            // `Greeter` and `Greeter.greet` both match `greet` with the same
            // score, so only the tie-break fixes their order.
            #expect(first.map(\.qualifiedPath) == ["Greeter", "Greeter.greet"])
            #expect(Set(first.map(\.score)).count == 1)

            for _ in 0..<Self.repeatedCallCount {
                let next = try await SymbolOps.searchSymbol(store: store, query: "greet")

                #expect(next.map(\.qualifiedPath) == first.map(\.qualifiedPath))
            }
        }
    }

    @Test
    func listSymbolsReturnsFileSymbolsInSourceOrder() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSymbolFixtures(store: store, root: root)

            let symbols = try await SymbolOps.listSymbols(store: store, file: "Sample.swift")

            let paths = symbols.map(\.qualifiedPath)
            #expect(
                paths == [
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

/// Seeds `store` with a chunker-populated Python class that has three
/// methods. The class chunk holds the text of each method chunk, so a pattern
/// in one method matches the class chunk and the method chunk.
///
/// The zero-based lines are: `class Model` at 0, `save` at 1 to 2,
/// `_save_table` at 4 to 5 and `_do_insert` at 7 to 8.
private func seedNestedClassFixture(store: Store, root: URL) async throws {
    try write(
        """
        class Model:
            def save(self):
                return self._save_table()

            def _save_table(self):
                return self._do_insert()

            def _do_insert(self):
                return 1
        """,
        to: "model.py",
        in: root
    )
    _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
    try await TreeSitterWorker.run(store: store, rootDirectory: root)
}

/// Seeds `store` with one chunker-populated file.
///
/// - Parameters:
///   - source: The text of the file.
///   - fileName: The path of the file, relative to `root`.
///   - store: The index store to fill.
///   - root: The workspace root.
private func seedSingleFileFixture(_ source: String, named fileName: String, store: Store, root: URL) async throws {
    try write(source, to: fileName, in: root)
    _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
    try await TreeSitterWorker.run(store: store, rootDirectory: root)
}

/// Tests for `GrepCode`: regex matching over `ts_chunks.text` with position
/// reporting, language/file-pattern filters, and `maxResults` capping.
struct GrepCodeTests {
    /// How many times `grepCodeKeepsEachArrowFunctionOnOneLineInEveryCall`
    /// sends its query, to show that the result does not change from one
    /// call to the next.
    private static let repeatedCallCount = 5

    @Test
    func grepCodeAnswersAMatchInOneMethodWithThatMethodNotTheClass() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedNestedClassFixture(store: store, root: root)

            let result = try await GrepCode.run(store: store, pattern: "def _save_table")

            #expect(result.matches.map(\.symbolPath) == ["Model._save_table"])
            let match = try #require(result.matches.first)
            #expect(match.startLine == 4)
            #expect(match.endLine == 5)
            #expect(!result.truncated)
        }
    }

    @Test
    func grepCodeAnswersMatchesInTwoMethodsWithTheTwoMethods() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedNestedClassFixture(store: store, root: root)

            let result = try await GrepCode.run(store: store, pattern: "def _save_table|def _do_insert")

            #expect(result.matches.map(\.symbolPath) == ["Model._save_table", "Model._do_insert"])
        }
    }

    @Test
    func grepCodeKeepsTheClassForAMatchOnTheClassLineOnly() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedNestedClassFixture(store: store, root: root)

            let result = try await GrepCode.run(store: store, pattern: "class Model|def _do_insert")

            #expect(result.matches.map(\.symbolPath) == ["Model", "Model._do_insert"])
            let classMatch = try #require(result.matches.first)
            #expect(classMatch.matches.count == 1)
        }
    }

    @Test
    func grepCodeKeepsTheMatchOfEachSiblingFunctionOnOneLine() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSingleFileFixture(
                "function a() { return NEEDLE; } function b() { return NEEDLE; }\n",
                named: "siblings.js",
                store: store,
                root: root
            )

            let result = try await GrepCode.run(store: store, pattern: "NEEDLE")

            #expect(result.matches.map(\.symbolPath) == ["a", "b"])
        }
    }

    @Test
    func grepCodeAnswersAMatchInAnExportedFunctionWithTheFunction() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSingleFileFixture(
                "export function foo() {\n    return NEEDLE;\n}\n",
                named: "exported.js",
                store: store,
                root: root
            )

            let result = try await GrepCode.run(store: store, pattern: "NEEDLE")

            #expect(result.matches.map(\.symbolPath) == ["foo"])
        }
    }

    @Test
    func grepCodeKeepsEachArrowFunctionOnOneLineInEveryCall() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSingleFileFixture(
                "const x = () => NEEDLE + 1; const y = () => NEEDLE + 2;\n",
                named: "arrows.js",
                store: store,
                root: root
            )

            for _ in 0..<Self.repeatedCallCount {
                let result = try await GrepCode.run(store: store, pattern: "NEEDLE")

                #expect(result.matches.map(\.text) == ["() => NEEDLE + 1", "() => NEEDLE + 2"])
            }
        }
    }

    @Test
    func grepCodeGivesAZeroLengthMatchAtTheEndOfAMethodToTheClass() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            let source = "class A:\n    def f(self):\n        return x\n\n    y = 1\n"
            let methodText = "def f(self):\n        return x"
            try await seedSingleFileFixture(source, named: "boundary.py", store: store, root: root)
            let methodRange = try #require(source.range(of: methodText))
            let methodEndByte = source.utf8.distance(from: source.startIndex, to: methodRange.upperBound)

            let result = try await GrepCode.run(store: store, pattern: #"\b"#)

            // The class starts at byte 0 of the file, so an offset in its text
            // is also an offset in the file.
            let classMatch = try #require(result.matches.first { $0.symbolPath == "A" })
            #expect(classMatch.matches.map(\.start).contains(methodEndByte))
            for match in result.matches {
                #expect(match.matches.allSatisfy { $0.start < match.text.utf8.count })
            }
        }
    }

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
            #expect(position.start == 5)  // "func " is 5 ASCII bytes
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
    func grepCodeOnACompleteIndexTellsThatTheIndexIsNotPartial() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSingleFileFixture("func hello() {}\n", named: "Sample.swift", store: store, root: root)

            let result = try await GrepCode.run(store: store, pattern: "hello")

            #expect(result.unindexedFiles == 0)
            #expect(!result.isIndexPartial)
        }
    }

    @Test
    func grepCodeTellsHowManyFilesTheIndexDoesNotHoldYet() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try await seedSingleFileFixture("func hello() {}\n", named: "Sample.swift", store: store, root: root)
            // The reconcile finds the two new files, but no tree-sitter pass
            // indexes them before the search.
            try write("func hello() {}\n", to: "Pending.swift", in: root)
            try write("def hello():\n    pass\n", to: "pending.py", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let result = try await GrepCode.run(store: store, pattern: "hello")

            #expect(result.unindexedFiles == 2)
            #expect(result.isIndexPartial)
            #expect(result.matches.map(\.filePath) == ["Sample.swift"])
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
