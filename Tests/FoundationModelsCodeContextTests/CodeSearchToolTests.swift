import Foundation
import FoundationModels
import Operations
import Testing

@testable import FoundationModelsCodeContext

/// Tests the operations of the `code_search` tool.
///
/// Each test indexes a small Swift fixture and calls the tool as the model
/// calls it: with a `GeneratedContent` payload. The fixture has no project
/// marker, so no LSP daemon starts, and the tree-sitter layer gives the
/// symbols and the call edges.
struct CodeSearchToolTests {
    /// The file of the fixture, relative to the workspace root.
    private static let fixtureFile = "Greeter.swift"

    /// The dimension of the fake embedding vectors.
    private static let embeddingDimension = 8

    /// A fixture with two symbols: `Greeter.greet()` calls the free function
    /// `helper()`.
    private static let fixtureSource = """
        struct Greeter {
            func greet() -> String {
                return helper()
            }
        }

        func helper() -> String {
            "hello"
        }
        """

    /// The shared description of the `query` parameter.
    private static let queryDescription =
        "Text to search for: a symbol name for `get symbol` and `search symbol`, or free text for `search code`."

    /// The shared description of the `symbol` parameter.
    private static let symbolDescription =
        "For `get callgraph`: a symbol name, or a `<file>:<line>:<column>` locator with 0-based numbers. "
        + "For `get blastradius`: the name of a symbol inside `file`."

    /// The shared description of the `file` parameter.
    private static let fileDescription = "A file path relative to the workspace root."

    /// The description of the `astQuery` parameter.
    private static let astQueryDescription =
        "A tree-sitter S-expression query, for example `(function_declaration) @function`."

    /// An S-expression query that matches each Swift function declaration.
    private static let astQuery = "(function_declaration) @function"

    /// The language of the fixture, for the `query ast` calls.
    private static let fixtureLanguage = "swift"

    /// The glob of the `grep code` calls that give a glob.
    private static let fixtureGlob = "*.swift"

    /// The regular expression of the `grep code` calls. It matches the free
    /// function of the fixture.
    private static let grepPattern = "helper"

    /// The free text of the `search code` calls.
    private static let searchText = "hello"

    /// The maximum number of results of the calls that give a maximum.
    private static let callMaxResults = 5

    /// The number of hits of the `search code` calls that give a number.
    private static let callTopK = 3

    /// The minimum similarity of the `find duplicates` calls that give one.
    private static let callMinSimilarity = 0.5

    /// The minimum chunk size, in bytes, of the `find duplicates` calls that
    /// give one.
    private static let callMinChunkBytes = 1

    /// The maximum number of duplicates for one chunk of the `find duplicates`
    /// calls that give one.
    private static let callMaxPerChunk = 2

    /// Indexes the fixture, makes the tool, and gives the tool and the
    /// `CodeContext` to `body`.
    ///
    /// - Parameter body: The test body.
    /// - Throws: The error that the setup or `body` throws.
    private static func withIndexedTool(
        _ body: (OperationTool<CodeContextToolContext>, CodeContext<FakeLanguageServerConnection>) async throws -> Void
    ) async throws {
        try await ToolTest.withIndexedTool(
            source: fixtureSource,
            file: fixtureFile,
            embeddingDimension: embeddingDimension,
            make: CodeSearchTool.make,
            body
        )
    }

    // MARK: - The tool

    @Test
    func toolExposesNineOperations() async throws {
        try await Self.withIndexedTool { tool, _ in
            #expect(tool.name == "code_search")
            #expect(
                tool.operations.map(\.opString) == [
                    "get symbol", "search symbol", "list symbol", "get callgraph", "get blastradius",
                    "grep code", "search code", "find duplicates", "query ast",
                ]
            )
        }
    }

    // MARK: - The operations

    @Test
    func eachOperationReturnsTheJSONOfTheEngineResult() async throws {
        try await Self.withIndexedTool { tool, context in
            let symbol = try await context.getSymbol(query: "greet", maxResults: 1)
            let matches = try await context.searchSymbol(query: "helper", kind: .function, maxResults: 1)
            let locations = try await context.listSymbols(file: Self.fixtureFile)
            let graph = try await context.callGraph(of: "helper", direction: .inbound, maxDepth: 1)
            let radius = try await context.blastRadius(file: Self.fixtureFile, symbol: "helper", maxHops: 1)

            #expect(symbol.symbols.contains { $0.name == "greet" })
            #expect(matches.contains { $0.name == "helper" })
            #expect(locations.contains { $0.name == "helper" })
            #expect(graph.root.name == "helper")
            #expect(!radius.roots.isEmpty)

            try await ToolTest.expectEachCall(
                [
                    (
                        GeneratedContent(properties: ["op": "get symbol", "query": "greet", "maxResults": 1]),
                        try TestJSON.encodedText(symbol)
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "search symbol", "query": "helper", "kind": "Function", "maxResults": 1,
                        ]),
                        try TestJSON.encodedText(matches)
                    ),
                    (
                        GeneratedContent(properties: ["op": "list symbol", "file": Self.fixtureFile]),
                        try TestJSON.encodedText(locations)
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "get callgraph", "symbol": "helper", "direction": "INBOUND", "maxDepth": 1,
                        ]),
                        try TestJSON.encodedText(graph)
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "get blastradius", "file": Self.fixtureFile, "symbol": "helper", "maxHops": 1,
                        ]),
                        try TestJSON.encodedText(radius)
                    ),
                ],
                on: tool
            )
        }
    }

    @Test
    func defaultsMatchTheDirectEngineCall() async throws {
        try await Self.withIndexedTool { tool, context in
            let graph = try await context.callGraph(of: "greet")
            let radius = try await context.blastRadius(file: Self.fixtureFile)
            let symbol = try await context.getSymbol(query: "greet")
            // `Greeter` and `Greeter.greet` have the same score, so this query
            // shows that the engine gives the tied matches a fixed order.
            let matches = try await context.searchSymbol(query: "greet")

            try await ToolTest.expectEachCall(
                [
                    (
                        GeneratedContent(properties: ["op": "get callgraph", "symbol": "greet"]),
                        try TestJSON.encodedText(graph)
                    ),
                    (
                        GeneratedContent(properties: ["op": "get blastradius", "file": Self.fixtureFile]),
                        try TestJSON.encodedText(radius)
                    ),
                    (
                        GeneratedContent(properties: ["op": "get symbol", "query": "greet"]),
                        try TestJSON.encodedText(symbol)
                    ),
                    (
                        GeneratedContent(properties: ["op": "search symbol", "query": "greet"]),
                        try TestJSON.encodedText(matches)
                    ),
                ],
                on: tool
            )
        }
    }

    // MARK: - The aliases

    @Test
    func aliasesDispatchToTheCanonicalOperation() async throws {
        try await Self.withIndexedTool { tool, context in
            let graph = try TestJSON.encodedText(try await context.callGraph(of: "greet"))
            let symbol = try TestJSON.encodedText(try await context.getSymbol(query: "greet"))
            let radius = try TestJSON.encodedText(try await context.blastRadius(file: Self.fixtureFile))
            let locations = try TestJSON.encodedText(try await context.listSymbols(file: Self.fixtureFile))

            try await ToolTest.expectEachCall(
                [
                    (GeneratedContent(properties: ["op": "get call_graph", "symbol": "greet"]), graph),
                    (GeneratedContent(properties: ["op": "callgraph get", "symbol": "greet"]), graph),
                    (GeneratedContent(properties: ["op": "lookup symbol", "query": "greet"]), symbol),
                    (GeneratedContent(properties: ["op": "get impact", "file": Self.fixtureFile]), radius),
                    (GeneratedContent(properties: ["op": "get symbol", "name": "greet"]), symbol),
                    (GeneratedContent(properties: ["op": "list symbol", "path": Self.fixtureFile]), locations),
                    (GeneratedContent(properties: ["op": "ls symbols", "file": Self.fixtureFile]), locations),
                ],
                on: tool
            )
        }
    }

    // MARK: - The corrective output

    @Test
    func anUnknownSymbolForGetCallgraphGivesACorrectiveString() async throws {
        try await Self.withIndexedTool { tool, _ in
            let output = try await tool.call(
                arguments: GeneratedContent(properties: ["op": "get callgraph", "symbol": "noSuchSymbol"])
            )

            #expect(
                try ToolTest.decodedString(output)
                    == ToolSupport.correctiveMessage(for: .notFound("symbol not found: noSuchSymbol"))
            )
        }
    }

    @Test
    func anInvalidDirectionGivesACorrectiveString() async throws {
        try await Self.withIndexedTool { tool, _ in
            let output = try await tool.call(
                arguments: GeneratedContent(properties: [
                    "op": "get callgraph", "symbol": "greet", "direction": "sideways",
                ])
            )

            #expect(
                try ToolTest.decodedString(output)
                    == "`sideways` is not a valid value for `direction`. Use one of: inbound, outbound, both."
            )
        }
    }

    // MARK: - The fused schema

    @Test
    func sharedParameterDescriptionsAreTheSharedText() async throws {
        try await Self.withIndexedTool { tool, _ in
            let schema = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(tool.parameters))
            let properties = try #require((schema as? [String: Any])?["properties"] as? [String: Any])
            let descriptions: [(name: String, expected: String)] = [
                (name: "query", expected: Self.queryDescription),
                (name: "symbol", expected: Self.symbolDescription),
                (name: "file", expected: Self.fileDescription),
            ]

            for parameter in descriptions {
                let property = try #require(properties[parameter.name] as? [String: Any], "parameter: \(parameter.name)")
                #expect(property["description"] as? String == parameter.expected, "parameter: \(parameter.name)")
            }
        }
    }

    @Test
    func fusedSchemaHasAstQueryParameter() async throws {
        try await Self.withIndexedTool { tool, _ in
            let schema = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(tool.parameters))
            let properties = try #require((schema as? [String: Any])?["properties"] as? [String: Any])
            let astQuery = try #require(properties["astQuery"] as? [String: Any])

            #expect(astQuery["description"] as? String == Self.astQueryDescription)
        }
    }

    // MARK: - The text, similarity and AST operations

    @Test
    func eachNewOperationReturnsTheJSONOfTheEngineResult() async throws {
        try await Self.withIndexedTool { tool, context in
            let grep = try await context.grepCode(
                pattern: Self.grepPattern,
                languages: [Self.fixtureLanguage],
                filePattern: Self.fixtureGlob,
                maxResults: Self.callMaxResults
            )
            let hits = try await context.searchCode(query: Self.searchText, topK: Self.callTopK)
            let duplicates = try await context.findDuplicates(
                file: Self.fixtureFile,
                minSimilarity: Self.callMinSimilarity,
                minChunkBytes: Self.callMinChunkBytes,
                maxPerChunk: Self.callMaxPerChunk
            )
            let ast = try await context.queryAST(
                language: Self.fixtureLanguage,
                query: Self.astQuery,
                options: QueryASTOptions(maxResults: Self.callMaxResults)
            )

            #expect(grep.pattern == Self.grepPattern)
            #expect(hits.query == Self.searchText)
            #expect(!ast.matches.isEmpty)

            try await ToolTest.expectEachCall(
                [
                    (
                        GeneratedContent(properties: [
                            "op": "grep code", "pattern": Self.grepPattern, "languages": [Self.fixtureLanguage],
                            "filePattern": Self.fixtureGlob, "maxResults": Self.callMaxResults,
                        ]),
                        try TestJSON.encodedText(grep)
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "search code", "query": Self.searchText, "topK": Self.callTopK,
                        ]),
                        try TestJSON.encodedText(hits)
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "find duplicates", "file": Self.fixtureFile,
                            "minSimilarity": Self.callMinSimilarity, "minChunkBytes": Self.callMinChunkBytes,
                            "maxPerChunk": Self.callMaxPerChunk,
                        ]),
                        try TestJSON.encodedText(duplicates)
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "query ast", "language": Self.fixtureLanguage, "astQuery": Self.astQuery,
                            "maxResults": Self.callMaxResults,
                        ]),
                        try TestJSON.encodedText(ast)
                    ),
                ],
                on: tool
            )
        }
    }

    @Test
    func newOperationDefaultsMatchTheDirectEngineCall() async throws {
        try await Self.withIndexedTool { tool, context in
            let grep = try await context.grepCode(pattern: Self.grepPattern)
            let hits = try await context.searchCode(query: Self.searchText)
            let duplicates = try await context.findDuplicates()
            let ast = try await context.queryAST(language: Self.fixtureLanguage, query: Self.astQuery)

            try await ToolTest.expectEachCall(
                [
                    (
                        GeneratedContent(properties: ["op": "grep code", "pattern": Self.grepPattern]),
                        try TestJSON.encodedText(grep)
                    ),
                    (
                        GeneratedContent(properties: ["op": "search code", "query": Self.searchText]),
                        try TestJSON.encodedText(hits)
                    ),
                    (
                        GeneratedContent(properties: ["op": "find duplicates"]),
                        try TestJSON.encodedText(duplicates)
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "query ast", "language": Self.fixtureLanguage, "astQuery": Self.astQuery,
                        ]),
                        try TestJSON.encodedText(ast)
                    ),
                ],
                on: tool
            )
        }
    }

    @Test
    func newOperationAliasesDispatch() async throws {
        try await Self.withIndexedTool { tool, context in
            let grep = try TestJSON.encodedText(try await context.grepCode(pattern: Self.grepPattern))
            let hits = try TestJSON.encodedText(try await context.searchCode(query: Self.searchText))
            let limited = try TestJSON.encodedText(
                try await context.searchCode(query: Self.searchText, topK: Self.callMaxResults)
            )
            let duplicates = try TestJSON.encodedText(try await context.findDuplicates())
            let ast = try TestJSON.encodedText(
                try await context.queryAST(language: Self.fixtureLanguage, query: Self.astQuery)
            )

            try await ToolTest.expectEachCall(
                [
                    (
                        GeneratedContent(properties: [
                            "op": "query ast", "language": Self.fixtureLanguage, "query": Self.astQuery,
                        ]),
                        ast
                    ),
                    (GeneratedContent(properties: ["op": "grep code", "regex": Self.grepPattern]), grep),
                    (
                        GeneratedContent(properties: [
                            "op": "search code", "query": Self.searchText, "limit": Self.callMaxResults,
                        ]),
                        limited
                    ),
                    (GeneratedContent(properties: ["op": "find dupes"]), duplicates),
                    (GeneratedContent(properties: ["op": "search source", "query": Self.searchText]), hits),
                ],
                on: tool
            )
        }
    }

    @Test
    func anInvalidGrepPatternGivesACorrectiveString() async throws {
        try await Self.withIndexedTool { tool, _ in
            let output = try await tool.call(
                arguments: GeneratedContent(properties: ["op": "grep code", "pattern": "("])
            )
            let message = try ToolTest.decodedString(output)

            #expect(message.hasPrefix("The pattern is not a valid regular expression:"))
            #expect(message.hasSuffix("Correct the pattern, then try again."))
        }
    }

    @Test
    func anInvalidAstQueryGivesACorrectiveString() async throws {
        try await Self.withIndexedTool { tool, _ in
            let output = try await tool.call(
                arguments: GeneratedContent(properties: [
                    "op": "query ast", "language": Self.fixtureLanguage, "astQuery": "(not_a_valid_node_type @x)",
                ])
            )
            let message = try ToolTest.decodedString(output)

            #expect(message.hasPrefix("The AST query failed:"))
            #expect(message.hasSuffix("Correct the language or the query, then try again."))
        }
    }
}
