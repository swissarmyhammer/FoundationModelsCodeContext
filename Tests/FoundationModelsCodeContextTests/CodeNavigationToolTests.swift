import Foundation
import FoundationModels
import Operations
import Testing

@testable import FoundationModelsCodeContext

/// Tests the position operations of the `code_navigation` tool.
///
/// Each test indexes a small Swift fixture and calls the tool as the model
/// calls it: with a `GeneratedContent` payload. The fixture has no project
/// marker, so no LSP daemon starts. Each operation then falls back to the LSP
/// index, and the `sourceLayer` of each result is `lspIndex`.
struct CodeNavigationToolTests {
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

    /// The line of the free function `helper` of the fixture. The first line
    /// of the file is line 0.
    private static let helperLine = 6

    /// A character offset inside the name `helper` on `helperLine`. The first
    /// character of the line is character 0.
    private static let helperCharacter = 5

    /// The maximum number of results of the calls that give a maximum.
    private static let callMaxResults = 5

    /// The op strings of the five position operations, in the order of the
    /// fused schema.
    private static let operationStrings = [
        "get definition", "get type_definition", "get hover", "get references", "get implementations",
    ]

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
            make: CodeNavigationTool.make,
            body
        )
    }

    // MARK: - The tool

    @Test
    func toolExposesTheFivePositionOperations() async throws {
        try await Self.withIndexedTool { tool, _ in
            #expect(tool.name == "code_navigation")
            #expect(tool.operations.map(\.opString) == Self.operationStrings)
        }
    }

    // MARK: - The operations

    @Test
    func eachOperationReturnsTheJSONOfTheEngineResult() async throws {
        try await Self.withIndexedTool { tool, context in
            let definition = try await context.definition(
                filePath: Self.fixtureFile, line: Self.helperLine, character: Self.helperCharacter, includeSource: true
            )
            let typeDefinition = try await context.typeDefinition(
                filePath: Self.fixtureFile, line: Self.helperLine, character: Self.helperCharacter, includeSource: true
            )
            let hover = try await context.hover(
                filePath: Self.fixtureFile, line: Self.helperLine, character: Self.helperCharacter
            )
            let references = try await context.references(
                filePath: Self.fixtureFile, line: Self.helperLine, character: Self.helperCharacter,
                includeDeclaration: true, maxResults: Self.callMaxResults
            )
            let implementations = try await context.implementations(
                filePath: Self.fixtureFile, line: Self.helperLine, character: Self.helperCharacter,
                includeSource: true, maxResults: Self.callMaxResults
            )

            #expect(definition.sourceLayer == .lspIndex)
            #expect(typeDefinition.sourceLayer == .lspIndex)
            #expect(hover.sourceLayer == .lspIndex)
            #expect(references.sourceLayer == .lspIndex)
            #expect(implementations.sourceLayer == .lspIndex)

            try await ToolTest.expectEachCall(
                [
                    (
                        GeneratedContent(properties: [
                            "op": "get definition", "file": Self.fixtureFile, "line": Self.helperLine,
                            "character": Self.helperCharacter, "includeSource": true,
                        ]),
                        try TestJSON.encodedText(definition)
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "get type_definition", "file": Self.fixtureFile, "line": Self.helperLine,
                            "character": Self.helperCharacter, "includeSource": true,
                        ]),
                        try TestJSON.encodedText(typeDefinition)
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "get hover", "file": Self.fixtureFile, "line": Self.helperLine,
                            "character": Self.helperCharacter,
                        ]),
                        try TestJSON.encodedText(hover)
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "get references", "file": Self.fixtureFile, "line": Self.helperLine,
                            "character": Self.helperCharacter, "includeDeclaration": true,
                            "maxResults": Self.callMaxResults,
                        ]),
                        try TestJSON.encodedText(references)
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "get implementations", "file": Self.fixtureFile, "line": Self.helperLine,
                            "character": Self.helperCharacter, "includeSource": true,
                            "maxResults": Self.callMaxResults,
                        ]),
                        try TestJSON.encodedText(implementations)
                    ),
                ],
                on: tool
            )
        }
    }

    @Test
    func defaultsMatchTheDirectEngineCall() async throws {
        try await Self.withIndexedTool { tool, context in
            let definition = try await context.definition(
                filePath: Self.fixtureFile, line: Self.helperLine, character: Self.helperCharacter
            )
            let references = try await context.references(
                filePath: Self.fixtureFile, line: Self.helperLine, character: Self.helperCharacter
            )
            let implementations = try await context.implementations(
                filePath: Self.fixtureFile, line: Self.helperLine, character: Self.helperCharacter
            )

            try await ToolTest.expectEachCall(
                [
                    (
                        GeneratedContent(properties: [
                            "op": "get definition", "file": Self.fixtureFile, "line": Self.helperLine,
                            "character": Self.helperCharacter,
                        ]),
                        try TestJSON.encodedText(definition)
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "get references", "file": Self.fixtureFile, "line": Self.helperLine,
                            "character": Self.helperCharacter,
                        ]),
                        try TestJSON.encodedText(references)
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "get implementations", "file": Self.fixtureFile, "line": Self.helperLine,
                            "character": Self.helperCharacter,
                        ]),
                        try TestJSON.encodedText(implementations)
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
            let definition = try TestJSON.encodedText(
                try await context.definition(
                    filePath: Self.fixtureFile, line: Self.helperLine, character: Self.helperCharacter
                )
            )
            let typeDefinition = try TestJSON.encodedText(
                try await context.typeDefinition(
                    filePath: Self.fixtureFile, line: Self.helperLine, character: Self.helperCharacter
                )
            )
            let hover = try TestJSON.encodedText(
                try await context.hover(
                    filePath: Self.fixtureFile, line: Self.helperLine, character: Self.helperCharacter
                )
            )
            let references = try TestJSON.encodedText(
                try await context.references(
                    filePath: Self.fixtureFile, line: Self.helperLine, character: Self.helperCharacter
                )
            )

            try await ToolTest.expectEachCall(
                [
                    (
                        GeneratedContent(properties: [
                            "op": "get typedefinition", "file": Self.fixtureFile, "line": Self.helperLine,
                            "character": Self.helperCharacter,
                        ]),
                        typeDefinition
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "type_definition get", "file": Self.fixtureFile, "line": Self.helperLine,
                            "character": Self.helperCharacter,
                        ]),
                        typeDefinition
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "goto def", "file": Self.fixtureFile, "line": Self.helperLine,
                            "character": Self.helperCharacter,
                        ]),
                        definition
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "find references", "file": Self.fixtureFile, "line": Self.helperLine,
                            "character": Self.helperCharacter,
                        ]),
                        references
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "find reference", "file": Self.fixtureFile, "line": Self.helperLine,
                            "character": Self.helperCharacter,
                        ]),
                        references
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "get refs", "file": Self.fixtureFile, "line": Self.helperLine,
                            "character": Self.helperCharacter,
                        ]),
                        references
                    ),
                    (
                        GeneratedContent(properties: [
                            "op": "get hover", "path": Self.fixtureFile, "row": Self.helperLine,
                            "column": Self.helperCharacter,
                        ]),
                        hover
                    ),
                ],
                on: tool
            )
        }
    }

    // MARK: - The corrective output

    @Test
    func aMissingLineGivesTheCorrectiveOutput() async throws {
        try await Self.withIndexedTool { tool, _ in
            let output = try await tool.call(
                arguments: GeneratedContent(properties: [
                    "op": "get hover", "file": Self.fixtureFile, "character": Self.helperCharacter,
                ])
            )

            #expect(output == "Missing required parameter(s): line.")
        }
    }
}
