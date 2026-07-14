import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `QueryAST`: compiling and running tree-sitter S-expression
/// queries against files on disk, capture correctness, error paths for
/// malformed queries and unknown languages, `maxResults` truncation, and
/// gitignore exclusion — port of the Rust `query_ast` test suite
/// (`crates/swissarmyhammer-code-context/src/ops/query_ast.rs`).
struct QueryASTTests {
    @Test
    func simpleFunctionQueryReturnsExpectedCaptureNamesAndRanges() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn hello() {}\nfn world() {}\n", to: "test.rs", in: root)

            let result = try QueryAST.run(
                rootDirectory: root,
                language: "rust",
                query: "(function_item name: (identifier) @name)"
            )

            #expect(result.filesScanned == 1)
            #expect(result.matches.count == 2)
            #expect(result.truncated == false)

            let first = try #require(result.matches.first)
            #expect(first.file == "test.rs")
            let firstCapture = try #require(first.captures.first)
            #expect(firstCapture.name == "name")
            #expect(firstCapture.kind == "identifier")
            #expect(firstCapture.text == "hello")
            #expect(firstCapture.startLine == 0)
            #expect(firstCapture.endLine == 0)
            #expect(firstCapture.startByte == 3)
            #expect(firstCapture.endByte == 8)

            let second = try #require(result.matches.last)
            let secondCapture = try #require(second.captures.first)
            #expect(secondCapture.text == "world")
            #expect(secondCapture.startLine == 1)
        }
    }

    @Test
    func maxResultsTruncatesAndReportsTruncated() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn a() {}\nfn b() {}\nfn c() {}\nfn d() {}\n", to: "test.rs", in: root)

            let result = try QueryAST.run(
                rootDirectory: root,
                language: "rust",
                query: "(function_item name: (identifier) @name)",
                options: QueryASTOptions(maxResults: 2)
            )

            #expect(result.matches.count == 2)
            #expect(result.truncated == true)
            #expect(result.filesScanned == 1)
        }
    }

    @Test
    func maxResultsStopsScanningFurtherFilesOnceReached() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn one() {}\nfn two() {}\n", to: "a.rs", in: root)
            try write("fn three() {}\n", to: "b.rs", in: root)

            let result = try QueryAST.run(
                rootDirectory: root,
                language: "rust",
                query: "(function_item name: (identifier) @name)",
                options: QueryASTOptions(maxResults: 1)
            )

            #expect(result.matches.count == 1)
            #expect(result.truncated == true)
            // b.rs is never parsed once a.rs alone satisfies maxResults.
            #expect(result.filesScanned == 1)
        }
    }

    @Test
    func malformedQueryThrowsDescriptiveError() async throws {
        try await withTemporaryWorkspace { root in
            do {
                _ = try QueryAST.run(rootDirectory: root, language: "rust", query: "(not_a_valid_node_type @x)")
                Issue.record("expected QueryAST.run to throw for a malformed query")
            } catch CodeContextError.query(let message) {
                #expect(message.lowercased().contains("query"))
            } catch {
                Issue.record("expected CodeContextError.query, got \(error)")
            }
        }
    }

    @Test
    func unknownLanguageThrowsDescriptiveError() async throws {
        try await withTemporaryWorkspace { root in
            do {
                _ = try QueryAST.run(rootDirectory: root, language: "not-a-real-language", query: "(identifier) @x")
                Issue.record("expected QueryAST.run to throw for an unknown language")
            } catch CodeContextError.query(let message) {
                #expect(message.lowercased().contains("language"))
            } catch {
                Issue.record("expected CodeContextError.query, got \(error)")
            }
        }
    }

    @Test
    func multipleCapturesInOneMatchPreserveDeclarationOrder() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn greet(name: &str) {}\n", to: "test.rs", in: root)

            let result = try QueryAST.run(
                rootDirectory: root,
                language: "rust",
                query: "(function_item name: (identifier) @fn_name parameters: (parameters) @params)"
            )

            #expect(result.matches.count == 1)
            let match = try #require(result.matches.first)
            #expect(match.captures.count == 2)
            #expect(match.captures[0].name == "fn_name")
            #expect(match.captures[0].text == "greet")
            #expect(match.captures[1].name == "params")
        }
    }

    @Test
    func multipleFilesAreScannedInDeterministicOrder() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn alpha() {}\n", to: "a.rs", in: root)
            try write("fn beta() {}\n", to: "b.rs", in: root)

            let result = try QueryAST.run(
                rootDirectory: root,
                language: "rust",
                query: "(function_item name: (identifier) @name)"
            )

            #expect(result.filesScanned == 2)
            #expect(result.matches.map { $0.captures.first?.text } == ["alpha", "beta"])
        }
    }

    @Test
    func noMatchesReturnsEmptyResultWithFileStillScanned() async throws {
        try await withTemporaryWorkspace { root in
            try write("let x = 42;\n", to: "test.rs", in: root)

            let result = try QueryAST.run(
                rootDirectory: root,
                language: "rust",
                query: "(function_item name: (identifier) @name)"
            )

            #expect(result.filesScanned == 1)
            #expect(result.matches.isEmpty)
        }
    }

    @Test
    func gitignoredFilesAreNeverScanned() async throws {
        try await withTemporaryWorkspace { root in
            try write("ignored.rs\n", to: ".gitignore", in: root)
            try write("fn ignored() {}\n", to: "ignored.rs", in: root)
            try write("fn kept() {}\n", to: "kept.rs", in: root)

            let result = try QueryAST.run(
                rootDirectory: root,
                language: "rust",
                query: "(function_item name: (identifier) @name)"
            )

            #expect(result.filesScanned == 1)
            #expect(result.matches.map { $0.file } == ["kept.rs"])
            #expect(result.matches.first?.captures.first?.text == "kept")
        }
    }

    @Test
    func defaultMaxResultsIsFifty() {
        #expect(QueryASTOptions().maxResults == 50)
    }

    @Test
    func languageMatchIsCaseInsensitive() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn hello() {}\n", to: "test.rs", in: root)

            let result = try QueryAST.run(
                rootDirectory: root,
                language: "Rust",
                query: "(function_item name: (identifier) @name)"
            )

            #expect(result.filesScanned == 1)
            #expect(result.matches.first?.captures.first?.text == "hello")
        }
    }
}
