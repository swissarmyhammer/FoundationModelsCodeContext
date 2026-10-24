import Foundation
import FoundationModels
import Operations
import Testing

@testable import FoundationModelsCodeContext

/// Tests that the tools give and take 1-based lines and columns.
///
/// The model reads a line from the tools of this package and gives it to a
/// file reader, which counts from 1. It also gives the tools the lines of a
/// traceback or a compiler message, which count from 1. The index and the
/// language servers count from 0, thus the tools convert at their boundary.
struct OneBasedToolSurfaceTests {
    /// The file of the fixture, relative to the workspace root.
    private static let fixtureFile = "lib.py"

    /// The dimension of the fake embedding vectors.
    private static let embeddingDimension = 8

    /// A Python fixture: `greet()` calls `helper()`.
    private static let fixtureSource = """
        import os

        def helper():
            return "hello"
        def greet():
            return helper()
        """

    /// The 1-based line of `def helper():`.
    private static let helperLine = 3

    /// The 1-based column of `helper` in `def helper():`.
    private static let helperColumn = 5

    /// The 1-based last line of `helper`.
    private static let helperEndLine = 4

    /// The 1-based line of the call `return helper()`.
    private static let callLine = 6

    /// The 1-based column of `helper` in `    return helper()`.
    private static let callColumn = 12

    /// Calls the tool that `make` makes with each set of arguments on the
    /// fixture, and gives each parsed output to `check`.
    ///
    /// - Parameters:
    ///   - arguments: The arguments of each call.
    ///   - make: Makes the tool from the tool context.
    ///   - check: Examines one parsed output.
    /// - Throws: The error that the setup, the tool or `check` throws.
    private static func expectOutputs(
        _ arguments: [GeneratedContent],
        make: @escaping (CodeContextToolContext) throws -> OperationTool<CodeContextToolContext>,
        _ check: (NSDictionary) throws -> Void
    ) async throws {
        try await ToolTest.withIndexedTool(
            source: fixtureSource,
            file: fixtureFile,
            embeddingDimension: embeddingDimension,
            make: make
        ) { tool, _ in
            for call in arguments {
                let output = try await tool.call(arguments: call)
                let object = try #require(
                    try JSONSerialization.jsonObject(with: Data(output.utf8), options: .fragmentsAllowed) as? NSDictionary,
                    "arguments: \(call.jsonString), output: \(output)"
                )
                try check(object)
            }
        }
    }

    /// Gives the first object in `list` whose `name` is `name`.
    private static func named(_ name: String, in list: Any?) throws -> NSDictionary {
        let objects = try #require(list as? [NSDictionary], "not a list: \(String(describing: list))")
        return try #require(objects.first { $0["name"] as? String == name }, "no \(name) in \(objects)")
    }

    // MARK: - Outputs

    @Test
    func theSymbolVerbsGiveTheLineOfTheSymbolFromOne() async throws {
        try await Self.expectOutputs(
            [GeneratedContent(properties: ["op": "get symbol", "query": "helper"])],
            make: { try CodeSearchTool.make(context: $0) }
        ) { output in
            let helper = try Self.named("helper", in: output["symbols"])
            #expect(helper["startLine"] as? Int == Self.helperLine)
            #expect(helper["endLine"] as? Int == Self.helperEndLine)
        }
        try await Self.expectOutputs(
            [GeneratedContent(properties: ["op": "list symbol", "file": Self.fixtureFile])],
            make: { try CodeSearchTool.make(context: $0) }
        ) { output in
            let helper = try Self.named("helper", in: output["symbols"])
            #expect(helper["startLine"] as? Int == Self.helperLine)
            #expect(helper["endLine"] as? Int == Self.helperEndLine)
        }
    }

    @Test
    func searchSymbolAndGrepCodeGiveTheLineFromOne() async throws {
        try await ToolTest.withIndexedTool(
            source: Self.fixtureSource,
            file: Self.fixtureFile,
            embeddingDimension: Self.embeddingDimension,
            make: { try CodeSearchTool.make(context: $0) }
        ) { tool, _ in
            let search = try JSONSerialization.jsonObject(
                with: Data(try await tool.call(arguments: GeneratedContent(properties: ["op": "search symbol", "query": "helper"])).utf8)
            )
            let helper = try Self.named("helper", in: (search as? NSDictionary)?["symbols"] ?? search)
            #expect(helper["startLine"] as? Int == Self.helperLine)

            let grep = try JSONSerialization.jsonObject(
                with: Data(try await tool.call(arguments: GeneratedContent(properties: ["op": "grep code", "pattern": "def helper"])).utf8)
            )
            let matches = try #require(((grep as? NSDictionary)?["matches"] ?? grep) as? [NSDictionary], "grep: \(grep)")
            #expect(matches.map { $0["startLine"] as? Int } == [Self.helperLine])
        }
    }

    @Test
    func definitionGivesTheRangeOfTheDeclarationFromOne() async throws {
        try await Self.expectOutputs(
            [
                GeneratedContent(properties: [
                    "op": "get definition", "file": Self.fixtureFile, "line": Self.callLine, "character": Self.callColumn,
                ])
            ],
            make: { try CodeNavigationTool.make(context: $0) }
        ) { output in
            let locations = try #require(output["locations"] as? [NSDictionary], "output: \(output)")
            #expect(locations.map { $0.value(forKeyPath: "range.start.line") as? Int } == [Self.helperLine])
            #expect(output["position"] == nil)
        }
    }

    // MARK: - Inputs

    @Test
    func theCallgraphLocatorCountsFromOne() async throws {
        try await Self.expectOutputs(
            [GeneratedContent(properties: ["op": "get callgraph", "symbol": "\(Self.fixtureFile):\(Self.helperEndLine):5"])],
            make: { try CodeSearchTool.make(context: $0) }
        ) { output in
            #expect(output.value(forKeyPath: "root.name") as? String == "helper", "output: \(output)")
        }
    }

    @Test
    func aCharacterOfZeroOrNoneIsTheStartOfTheLine() async throws {
        try await Self.expectOutputs(
            [
                GeneratedContent(properties: [
                    "op": "get definition", "file": Self.fixtureFile, "line": Self.helperLine, "character": 0,
                ]),
                GeneratedContent(properties: ["op": "get definition", "file": Self.fixtureFile, "line": Self.helperLine]),
            ],
            make: { try CodeNavigationTool.make(context: $0) }
        ) { output in
            #expect(output.value(forKeyPath: "position.line") as? Int == Self.helperLine)
            #expect(output.value(forKeyPath: "position.character") as? Int == Self.helperColumn)
            let locations = try #require(output["locations"] as? [NSDictionary], "output: \(output)")
            #expect(locations.map { $0.value(forKeyPath: "range.start.line") as? Int } == [Self.helperLine])
        }
    }

    @Test
    func lineZeroIsReadAsLineOneWithANote() async throws {
        try await Self.expectOutputs(
            [GeneratedContent(properties: ["op": "get hover", "file": Self.fixtureFile, "line": 0])],
            make: { try CodeNavigationTool.make(context: $0) }
        ) { output in
            #expect(output.value(forKeyPath: "position.line") as? Int == 1, "output: \(output)")
            #expect((output.value(forKeyPath: "position.note") as? String)?.contains("line 1") == true)
        }
    }

    @Test
    func theCoordinatesConvertAtTheBoundary() {
        #expect(ToolCoordinates.zeroBased(line: 1) == 0)
        #expect(ToolCoordinates.zeroBased(line: 7) == 6)
        #expect(ToolCoordinates.zeroBased(line: 0) == 0)
        #expect(ToolCoordinates.zeroBased(character: nil) == nil)
        #expect(ToolCoordinates.zeroBased(character: 0) == nil)
        #expect(ToolCoordinates.zeroBased(character: 1) == 0)
        #expect(ToolCoordinates.zeroBased(locator: "a/b.py:4:5") == "a/b.py:3:4")
        #expect(ToolCoordinates.zeroBased(locator: "a/b.py:0:0") == "a/b.py:0:0")
        #expect(ToolCoordinates.zeroBased(locator: "helper") == "helper")
    }

    @Test
    func theToolEncodingAddsOneToEachLineAndColumnKey() throws {
        let range = LSPRange(start: Position(line: 2, character: 4), end: Position(line: 3, character: 0))
        let json = try TestJSON.encodedText(range)

        #expect(json == #"{"end":{"character":1,"line":4},"start":{"character":5,"line":3}}"#)
    }
}
