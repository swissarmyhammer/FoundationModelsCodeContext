import Foundation
import FoundationModels
import Operations
import Testing

@testable import FoundationModelsCodeContext

/// Tests the symbol and graph operations of the `code_search` tool.
///
/// Each test indexes a small Swift fixture and calls the tool as the model
/// calls it: with a `GeneratedContent` payload. The fixture has no project
/// marker, so no LSP daemon starts, and the tree-sitter layer gives the
/// symbols and the call edges.
struct CodeSearchToolTests {
    /// One tool call, and the JSON text that the call must give.
    private typealias Call = (arguments: GeneratedContent, expected: String)

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

    /// Indexes the fixture, makes the tool, and gives the tool and the
    /// `CodeContext` to `body`. The `CodeContext` stops after `body`, also
    /// when `body` throws.
    ///
    /// - Parameter body: The test body.
    /// - Throws: The error that the setup or `body` throws.
    private static func withIndexedTool(
        _ body: (OperationTool<CodeContextToolContext>, CodeContext<FakeLanguageServerConnection>) async throws -> Void
    ) async throws {
        try await withTemporaryWorkspace { root in
            try write(fixtureSource, to: fixtureFile, in: root)
            let context = try await CodeContext<FakeLanguageServerConnection>(
                rootDirectory: root,
                embedder: FakeEmbedder(dimension: embeddingDimension),
                eventSource: FakeFileEventSource(),
                autoInstall: LspAutoInstall(isEnabled: false),
                connectionFactory: fakeConnectionFactory(pid: 1, processState: ProcessState())
            )
            try await context.start()
            do {
                try await body(try CodeSearchTool.make(context: CodeContextToolContext(operating: context)), context)
            } catch {
                await context.stop()
                throw error
            }
            await context.stop()
        }
    }

    /// Calls `tool` with the arguments of each call, and expects the JSON
    /// text of that call.
    ///
    /// - Parameters:
    ///   - calls: The tool calls and their expected JSON text.
    ///   - tool: The tool to call.
    /// - Throws: The error that the tool throws.
    private static func expectEachCall(_ calls: [Call], on tool: OperationTool<CodeContextToolContext>) async throws {
        for call in calls {
            let output = try await tool.call(arguments: call.arguments)
            #expect(output == call.expected, "arguments: \(call.arguments.jsonString)")
        }
    }

    /// Decodes a tool output that is one JSON string, for example a corrective
    /// message.
    ///
    /// - Parameter output: The tool output.
    /// - Returns: The decoded string.
    /// - Throws: A `DecodingError` when `output` is not one JSON string.
    private static func decodedString(_ output: String) throws -> String {
        try JSONDecoder().decode(String.self, from: Data(output.utf8))
    }

    // MARK: - The tool

    @Test
    func makeFusesTheFiveSymbolAndGraphOperations() async throws {
        try await Self.withIndexedTool { tool, _ in
            #expect(tool.name == "code_search")
            #expect(
                tool.operations.map(\.opString) == [
                    "get symbol", "search symbol", "list symbol", "get callgraph", "get blastradius",
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

            try await Self.expectEachCall(
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
            // No other match of `helper` has the same score, so the order of the
            // matches is fixed. Task ^a7byaqk adds a tie-break to the engine.
            let matches = try await context.searchSymbol(query: "helper")

            try await Self.expectEachCall(
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
                        GeneratedContent(properties: ["op": "search symbol", "query": "helper"]),
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

            try await Self.expectEachCall(
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
                try Self.decodedString(output)
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
                try Self.decodedString(output)
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
}
