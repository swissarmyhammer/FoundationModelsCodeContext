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

    /// The glob of the `grep code` calls that give a glob, and of the
    /// `get blastradius` calls that give a glob. It matches the fixture file.
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
            make: { try CodeSearchTool.make(context: $0) },
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

    // MARK: - The blast radius of a scope

    /// The callee file of the scope fixture. Its name sorts before
    /// `scopeCallerFile`, thus the index pass reads the callee first, and the
    /// tree-sitter layer can resolve the call of the caller to it.
    private static let scopeCalleeFile = "Callee.swift"

    /// The caller file of the scope fixture.
    private static let scopeCallerFile = "Caller.swift"

    /// The committed text of the callee file.
    private static let scopeCalleeSource = """
        func helper() -> String {
            "hello"
        }
        """

    /// The text of the callee file after the change that the scope finds.
    private static let scopeChangedCalleeSource = """
        func helper() -> String {
            "hello, world"
        }
        """

    /// The text of the caller file: `greet()` calls `helper()`.
    private static let scopeCallerSource = """
        func greet() -> String {
            helper()
        }
        """

    /// The commit of the scope `sha` calls: the commit before `HEAD`. The
    /// resolver reads a single commit name as `<name>..HEAD`, thus this name
    /// selects the files of the last commit.
    private static let lastCommitSha = "HEAD~1"

    /// Makes a git repository with the scope fixture, changes the callee file
    /// after the first commit, and gives the tool and the `CodeContext` to
    /// `body`.
    ///
    /// - Parameters:
    ///   - commitsTheChange: When `true`, a second commit holds the change of
    ///     the callee file, and the working tree is clean. When `false`, the
    ///     change stays in the working tree.
    ///   - body: The test body.
    /// - Throws: The error that the setup or `body` throws.
    private static func withChangedScopeFixture(
        commitsTheChange: Bool,
        _ body: (OperationTool<CodeContextToolContext>, CodeContext<FakeLanguageServerConnection>) async throws -> Void
    ) async throws {
        try await withTemporaryWorkspace { root in
            try write(scopeCalleeSource, to: scopeCalleeFile, in: root)
            try write(scopeCallerSource, to: scopeCallerFile, in: root)
            try await GitFixture.initRepo(at: root)
            try await GitFixture.commitAll(in: root, message: "initial")
            try write(scopeChangedCalleeSource, to: scopeCalleeFile, in: root)
            if commitsTheChange {
                try await GitFixture.commitAll(in: root, message: "change the callee")
            }

            try await ToolTest.withStartedContext(rootDirectory: root, embeddingDimension: embeddingDimension) { context in
                try await body(try CodeSearchTool.make(context: CodeContextToolContext(operating: context)), context)
            }
        }
    }

    /// Expects that `radius` gives `greet()` of the caller file as the one
    /// affected symbol.
    ///
    /// - Parameter radius: The blast radius of a scope that holds the callee
    ///   file.
    private static func expectTheCallerIsTheOneAffectedSymbol(of radius: BlastRadius) {
        #expect(!radius.roots.isEmpty, "the changed callee file has indexed symbols")
        let affected = radius.hops.flatMap(\.symbols)
        #expect(affected.map(\.name) == ["greet"])
        #expect(affected.map(\.filePath) == [scopeCallerFile])
    }

    @Test
    func blastRadiusOfTheWorkingTreeGivesTheCallersOfAChangedFile() async throws {
        try await Self.withChangedScopeFixture(commitsTheChange: false) { _, context in
            Self.expectTheCallerIsTheOneAffectedSymbol(of: try await context.blastRadius(scope: .workingTree))
        }
    }

    @Test
    func theScopeWorkingGivesTheBlastRadiusOfTheWorkingTree() async throws {
        try await Self.withChangedScopeFixture(commitsTheChange: false) { tool, context in
            let radius = try await context.blastRadius(scope: .workingTree)
            Self.expectTheCallerIsTheOneAffectedSymbol(of: radius)

            try await ToolTest.expectEachCall(
                [
                    (GeneratedContent(properties: ["op": "get blastradius", "scope": "working"]), try TestJSON.encodedText(radius)),
                    (GeneratedContent(properties: ["op": "get blastradius", "mode": "WORKING"]), try TestJSON.encodedText(radius)),
                ],
                on: tool
            )
        }
    }

    @Test
    func theScopeShaGivesTheBlastRadiusOfTheLastCommit() async throws {
        try await Self.withChangedScopeFixture(commitsTheChange: true) { tool, context in
            let radius = try await context.blastRadius(scope: .sha(Self.lastCommitSha))
            Self.expectTheCallerIsTheOneAffectedSymbol(of: radius)

            try await ToolTest.expectEachCall(
                [
                    (
                        GeneratedContent(properties: ["op": "get blastradius", "scope": "sha", "sha": Self.lastCommitSha]),
                        try TestJSON.encodedText(radius)
                    ),
                    (
                        GeneratedContent(properties: ["op": "get blastradius", "scope": "sha", "commit": Self.lastCommitSha]),
                        try TestJSON.encodedText(radius)
                    ),
                ],
                on: tool
            )
        }
    }

    @Test
    func aGlobFileGivesTheBlastRadiusOfEachMatchingFile() async throws {
        try await Self.withIndexedTool { tool, context in
            let radius = try await context.blastRadius(scope: .file(Self.fixtureGlob))
            #expect(!radius.roots.isEmpty, "the glob matches the fixture file")

            try await ToolTest.expectEachCall(
                [
                    (
                        GeneratedContent(properties: ["op": "get blastradius", "scope": "file", "file": Self.fixtureGlob]),
                        try TestJSON.encodedText(radius)
                    ),
                    (
                        GeneratedContent(properties: ["op": "get blastradius", "file": Self.fixtureGlob]),
                        try TestJSON.encodedText(radius)
                    ),
                ],
                on: tool
            )
        }
    }

    @Test
    func theScopeFileWithAPathGivesTheBlastRadiusOfTheFile() async throws {
        try await Self.withIndexedTool { tool, context in
            let radius = try await context.blastRadius(file: Self.fixtureFile, symbol: "helper")

            try await ToolTest.expectEachCall(
                [
                    (
                        GeneratedContent(properties: [
                            "op": "get blastradius", "scope": "file", "file": Self.fixtureFile, "symbol": "helper",
                        ]),
                        try TestJSON.encodedText(radius)
                    )
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

    /// The corrective message of a `get blastradius` call with no `file` for
    /// the scope `file`, or with no scope and no `file`.
    private static let missingFileMessage =
        "Give the parameter `file` for the scope `file`, or give the scope `working` or `sha`. "
        + "`file` accepts a path relative to the workspace root or a glob."

    @Test
    func getBlastradiusWithAMissingParameterGivesACorrectiveString() async throws {
        try await Self.withIndexedTool { tool, _ in
            try await ToolTest.expectEachCorrectiveMessage(
                [
                    (
                        GeneratedContent(properties: ["op": "get blastradius", "scope": "sha"]),
                        "Give the parameter `sha` for the scope `sha`. It accepts a commit name or a `<from>..<to>` range."
                    ),
                    (GeneratedContent(properties: ["op": "get blastradius"]), Self.missingFileMessage),
                    (GeneratedContent(properties: ["op": "get blastradius", "scope": "file"]), Self.missingFileMessage),
                ],
                on: tool
            )
        }
    }

    @Test
    func getBlastradiusWithASymbolForAScopeOfFilesGivesACorrectiveString() async throws {
        try await Self.withIndexedTool { tool, _ in
            try await ToolTest.expectEachCorrectiveMessage(
                [
                    (
                        GeneratedContent(properties: ["op": "get blastradius", "scope": "working", "symbol": "helper"]),
                        "The parameter `symbol` is only for a `file` that is one path. Remove `symbol` for the scope `working`."
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "get blastradius", "scope": "sha", "sha": Self.lastCommitSha, "symbol": "helper",
                        ]),
                        "The parameter `symbol` is only for a `file` that is one path. Remove `symbol` for the scope `sha`."
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "get blastradius", "scope": "file", "file": Self.fixtureGlob, "symbol": "helper",
                        ]),
                        "The parameter `symbol` is only for a `file` that is one path. Remove `symbol` for a glob."
                    ),
                ],
                on: tool
            )
        }
    }

    @Test
    func getBlastradiusWithAnInvalidScopeGivesACorrectiveString() async throws {
        try await Self.withIndexedTool { tool, _ in
            let output = try await tool.call(
                arguments: GeneratedContent(properties: ["op": "get blastradius", "scope": "everything"])
            )

            #expect(
                try ToolTest.decodedString(output)
                    == "`everything` is not a valid value for `scope`. Use one of: working, file, sha."
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
