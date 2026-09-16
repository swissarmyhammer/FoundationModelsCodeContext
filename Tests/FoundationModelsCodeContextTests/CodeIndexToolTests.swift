import Foundation
import FoundationModels
import Operations
import Testing

@testable import FoundationModelsCodeContext

/// Tests the four operations of the `code_index` tool.
///
/// Each test indexes a small Swift fixture and calls the tool as the model
/// calls it: with a `GeneratedContent` payload. The workspace has no project
/// marker at `start()`, so no LSP daemon starts. The `detect projects` test
/// writes the marker after `start()`, because `detectProjects()` only
/// publishes the projects and starts no daemon.
struct CodeIndexToolTests {
    /// The file of the fixture, relative to the workspace root.
    private static let fixtureFile = "Greeter.swift"

    /// The dimension of the fake embedding vectors.
    private static let embeddingDimension = 8

    /// A fixture with one type and one method.
    private static let fixtureSource = """
        struct Greeter {
            func greet() -> String {
                "hello"
            }
        }
        """

    /// The op strings of the four operations, in the order of the fused schema.
    private static let operationStrings = [
        "get status", "get lsp_status", "rebuild index", "detect projects",
    ]

    /// The marker file that makes the workspace a Swift project.
    private static let swiftProjectMarker = "Package.swift"

    /// The text of the marker file.
    private static let swiftProjectMarkerSource = "// swift-tools-version: 6.2\n"

    /// The name of the language that `detect projects` must find.
    private static let swiftLanguageName = "swift"

    /// The name of the tree-sitter layer, as `RebuildLayer` spells it.
    private static let treeSitterLayerName = "treesitter"

    /// The name of the tree-sitter layer with a `_`. The match ignores `_`,
    /// so this name finds the same layer.
    private static let underscoredTreeSitterLayerName = "tree_sitter"

    /// A layer name that no `RebuildLayer` case holds.
    private static let invalidLayerName = "bogus"

    /// The corrective message of `invalidLayerName`.
    private static let invalidLayerMessage =
        "`\(invalidLayerName)` is not a valid value for `layer`. Use one of: treesitter, lsp, embedding, all."

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
            make: { try CodeIndexTool.make(context: $0) },
            body
        )
    }

    // MARK: - The tool

    @Test
    func toolExposesFourOperations() async throws {
        try await Self.withIndexedTool { tool, _ in
            #expect(tool.name == "code_index")
            #expect(tool.operations.map(\.opString) == Self.operationStrings)
        }
    }

    // MARK: - The operations

    @Test
    func theStatusOperationsReturnTheJSONOfTheEngineResult() async throws {
        try await Self.withIndexedTool { tool, context in
            let status = await context.indexStatus()
            let servers = await context.lspStatus()

            #expect(servers.isEmpty)

            try await ToolTest.expectEachCall(
                [
                    (
                        GeneratedContent(properties: ["op": "get status"]),
                        try TestJSON.encodedText(status)
                    ),
                    (
                        GeneratedContent(properties: ["op": "get lsp_status"]),
                        try TestJSON.encodedText(servers)
                    ),
                ],
                on: tool
            )
        }
    }

    @Test
    func rebuildIndexReturnsTheJSONOfTheEngineResult() async throws {
        try await Self.withIndexedTool { tool, context in
            let rebuild = try await context.rebuildIndex(layer: .treeSitter)

            #expect(rebuild.layer == .treeSitter)

            try await ToolTest.expectEachCall(
                [
                    (
                        GeneratedContent(properties: ["op": "rebuild index", "layer": Self.treeSitterLayerName]),
                        try TestJSON.encodedText(rebuild)
                    )
                ],
                on: tool
            )
        }
    }

    @Test
    func detectProjectsNamesTheSwiftProject() async throws {
        try await Self.withIndexedTool { tool, context in
            try write(Self.swiftProjectMarkerSource, to: Self.swiftProjectMarker, in: context.rootDirectory)
            let projects = try await context.detectProjects()

            #expect(projects.isEmpty == false)

            let output = try await tool.call(arguments: GeneratedContent(properties: ["op": "detect projects"]))

            #expect(output == (try TestJSON.encodedText(projects)))
            #expect(output.contains(Self.swiftLanguageName))
        }
    }

    // MARK: - The aliases

    @Test
    func aliasesDispatchToTheCanonicalOperation() async throws {
        try await Self.withIndexedTool { tool, context in
            try write(Self.swiftProjectMarkerSource, to: Self.swiftProjectMarker, in: context.rootDirectory)
            let status = try TestJSON.encodedText(await context.indexStatus())
            let servers = try TestJSON.encodedText(await context.lspStatus())
            let projects = try TestJSON.encodedText(try await context.detectProjects())
            let rebuild = try TestJSON.encodedText(try await context.rebuildIndex(layer: .treeSitter))

            try await ToolTest.expectEachCall(
                [
                    (GeneratedContent(properties: ["op": "get lspstatus"]), servers),
                    (GeneratedContent(properties: ["op": "get lsp"]), servers),
                    (GeneratedContent(properties: ["op": "get servers"]), servers),
                    (GeneratedContent(properties: ["op": "check state"]), status),
                    (GeneratedContent(properties: ["op": "get progress"]), status),
                    (GeneratedContent(properties: ["op": "scan projects"]), projects),
                    (GeneratedContent(properties: ["op": "list project"]), projects),
                    (GeneratedContent(properties: ["op": "discover projects"]), projects),
                    (
                        GeneratedContent(properties: ["op": "refresh index", "layer": Self.treeSitterLayerName]),
                        rebuild
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "rebuild index", "target": Self.underscoredTreeSitterLayerName,
                        ]),
                        rebuild
                    ),
                ],
                on: tool
            )
        }
    }

    // MARK: - The corrective output

    @Test
    func anInvalidLayerGivesTheCorrectiveOutput() async throws {
        try await Self.withIndexedTool { tool, _ in
            let output = try await tool.call(
                arguments: GeneratedContent(properties: ["op": "rebuild index", "layer": Self.invalidLayerName])
            )

            #expect(try ToolTest.decodedString(output) == Self.invalidLayerMessage)
        }
    }
}
