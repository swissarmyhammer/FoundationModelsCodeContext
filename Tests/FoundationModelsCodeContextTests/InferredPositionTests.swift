import Foundation
import FoundationModels
import Operations
import Testing

@testable import FoundationModelsCodeContext

/// Tests the position operations of the `code_navigation` tool when the model
/// does not give the column.
///
/// A model knows the file, the line and the name that it wants, but it rarely
/// knows the exact column. The operation then finds the column itself, and the
/// result tells the model which position it used.
struct InferredPositionTests {
    /// The file of the fixture, relative to the workspace root.
    private static let fixtureFile = "lib.py"

    /// The dimension of the fake embedding vectors.
    private static let embeddingDimension = 8

    /// A Python fixture: `greet()` calls `helper()`.
    private static let fixtureSource = """
        def helper():
            return "hello"


        def greet():
            return helper()
        """

    /// The line of `helper` in `def helper():`.
    private static let helperLine = 0

    /// The column of `helper` in `def helper():`.
    private static let helperCharacter = 4

    /// The line of the call `return helper()`.
    private static let callLine = 5

    /// The column of `helper` in `    return helper()`.
    private static let callCharacter = 11

    /// Calls `get definition` on the fixture with each set of arguments, and
    /// gives each output, parsed, to `check` together with the direct engine
    /// result at the real position.
    ///
    /// - Parameters:
    ///   - arguments: The arguments of each call.
    ///   - line: The line of the real position of the name.
    ///   - character: The column of the real position of the name.
    ///   - check: Examines one output.
    /// - Throws: The error that the setup, the tool or `check` throws.
    private static func expectDefinitions(
        _ arguments: [GeneratedContent],
        line: Int,
        character: Int,
        _ check: (NSDictionary, NSDictionary) throws -> Void
    ) async throws {
        try await ToolTest.withIndexedTool(
            source: fixtureSource,
            file: fixtureFile,
            embeddingDimension: embeddingDimension,
            make: { try CodeNavigationTool.make(context: $0) }
        ) { tool, context in
            let direct = try TestJSON.encodedObject(
                try await context.definition(filePath: fixtureFile, line: line, character: character)
            )
            for call in arguments {
                let output = try await tool.call(arguments: call)
                let object = try #require(
                    try JSONSerialization.jsonObject(with: Data(output.utf8), options: .fragmentsAllowed) as? NSDictionary,
                    "output: \(output)"
                )
                try check(object, direct)
            }
        }
    }

    @Test
    func getDefinitionWithNoCharacterAndWithASymbolFindsTheDefinitionOfHelper() async throws {
        try await Self.expectDefinitions(
            [
                GeneratedContent(properties: ["op": "get definition", "path": Self.fixtureFile, "line": Self.helperLine]),
                GeneratedContent(properties: [
                    "op": "get definition", "path": Self.fixtureFile, "line": Self.helperLine, "symbol": "helper",
                ]),
            ],
            line: Self.helperLine,
            character: Self.helperCharacter
        ) { output, direct in
            let locations = try #require(output["locations"] as? [NSDictionary])
            #expect(
                locations.contains {
                    $0["filePath"] as? String == Self.fixtureFile
                        && $0.value(forKeyPath: "range.start.line") as? Int == Self.helperLine
                        && $0.value(forKeyPath: "symbol.name") as? String == "helper"
                }
            )
            #expect(output["locations"] as? NSArray == direct["locations"] as? NSArray)
            #expect(output.value(forKeyPath: "position.line") as? Int == Self.helperLine)
            #expect(output.value(forKeyPath: "position.character") as? Int == Self.helperCharacter)
            #expect((output.value(forKeyPath: "position.note") as? String)?.contains("helper") == true)
        }
    }

    @Test
    func aCallLineWithNoCharacterOrWithASymbolUsesTheColumnOfTheCalledName() async throws {
        try await Self.expectDefinitions(
            [
                GeneratedContent(properties: ["op": "get definition", "path": Self.fixtureFile, "line": Self.callLine]),
                GeneratedContent(properties: [
                    "op": "get definition", "path": Self.fixtureFile, "line": Self.callLine, "symbol": "helper",
                ]),
                GeneratedContent(properties: [
                    "op": "get definition", "path": Self.fixtureFile, "line": Self.callLine, "name": "lib.helper",
                ]),
            ],
            line: Self.callLine,
            character: Self.callCharacter
        ) { output, direct in
            #expect(output["locations"] as? NSArray == direct["locations"] as? NSArray)
            #expect(output.value(forKeyPath: "position.line") as? Int == Self.callLine)
            #expect(output.value(forKeyPath: "position.character") as? Int == Self.callCharacter)
        }
    }

    @Test
    func anExactPositionGivesTheEngineResultWithNoPosition() async throws {
        try await Self.expectDefinitions(
            [
                GeneratedContent(properties: [
                    "op": "get definition", "path": Self.fixtureFile, "line": Self.helperLine, "col": Self.helperCharacter,
                ]),
                GeneratedContent(properties: [
                    "op": "get definition", "path": Self.fixtureFile, "line": Self.helperLine,
                    "character": Self.helperCharacter, "symbol": "helper",
                ]),
            ],
            line: Self.helperLine,
            character: Self.helperCharacter
        ) { output, direct in
            #expect(output == direct)
        }
    }

    // MARK: - PositionInference

    /// Resolves a position in the fixture text.
    private static func resolve(line: Int, character: Int? = nil, symbol: String? = nil) -> ResolvedPosition {
        PositionInference.resolve(text: fixtureSource, line: line, character: character, symbol: symbol)
    }

    @Test
    func theFirstNameOnTheLineSkipsKeywordsAndStrings() {
        #expect(Self.resolve(line: Self.helperLine).character == Self.helperCharacter)
        #expect(Self.resolve(line: Self.callLine).character == Self.callCharacter)
        #expect(
            PositionInference.resolve(text: "    return 'x' + value  # helper\n", line: 0, character: nil, symbol: nil).character == 17
        )
    }

    @Test
    func aSymbolOnANearbyLineMovesTheLineAndSaysSo() {
        let position = Self.resolve(line: 3, symbol: "greet")

        #expect(position == ResolvedPosition(line: 4, character: 4, note: position.note))
        #expect(position.note?.contains("line 4, not on line 3") == true)
    }

    @Test
    func aSymbolFarFromTheLineFallsBackToTheFirstName() {
        let position = PositionInference.resolve(
            text: "a = 1\n\n\n\n\nb = helper()\n", line: 0, character: nil, symbol: "helper"
        )

        #expect(position.line == 0)
        #expect(position.character == 0)
        #expect(position.note?.contains("`a`") == true)
    }

    @Test
    func aColumnOnePastTheEndIsReadAsOneBased() {
        let line = "def helper():"
        let position = PositionInference.resolve(text: line, line: 0, character: line.utf16.count, symbol: nil)

        #expect(position.character == line.utf16.count - 1)
        #expect(position.note?.contains("1-based") == true)
    }

    @Test
    func aColumnFarPastTheEndUsesTheFirstName() {
        let position = PositionInference.resolve(text: "def helper():", line: 0, character: 40, symbol: nil)

        #expect(position.character == Self.helperCharacter)
        #expect(position.note?.contains("Character 40") == true)
    }

    @Test
    func anExactColumnHasNoNote() {
        #expect(Self.resolve(line: Self.callLine, character: 4) == ResolvedPosition(line: Self.callLine, character: 4))
    }

    @Test
    func noTextOrALineOutsideTheFileKeepsTheArguments() {
        #expect(
            PositionInference.resolve(text: nil, line: 3, character: nil, symbol: "x") == ResolvedPosition(line: 3, character: 0)
        )
        #expect(Self.resolve(line: 99, character: 2) == ResolvedPosition(line: 99, character: 2))
    }
}
