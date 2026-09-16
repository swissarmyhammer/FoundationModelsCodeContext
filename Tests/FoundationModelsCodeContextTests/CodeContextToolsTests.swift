import Foundation
import FoundationModels
import Operations
import Testing

@testable import FoundationModelsCodeContext

/// Tests the public factory `CodeContextTools`, and the alias tables of the
/// three tools.
struct CodeContextToolsTests {
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

    /// The number of tools that `CodeContextTools.make` gives.
    private static let toolCount = 3

    /// The number of operations of the `code_search` tool.
    private static let searchOperationCount = 9

    /// The number of operations of the `code_navigation` tool.
    private static let navigationOperationCount = 10

    /// The number of operations of the `code_index` tool.
    private static let indexOperationCount = 4

    /// The instructions of the session of
    /// `toolsCanBeRegisteredOnALanguageModelSession`.
    private static let sessionInstructions = "Test session"

    /// The expected number of operations of each tool, with the name of the
    /// tool as the key.
    private static let expectedOperationCounts = [
        CodeSearchTool.name: searchOperationCount,
        CodeNavigationTool.name: navigationOperationCount,
        CodeIndexTool.name: indexOperationCount,
    ]

    /// The tables of one tool, as `aliasTablesAreSafe` reads them.
    private struct ToolTables {
        /// The name of the tool.
        let name: String

        /// The verb aliases of the tool, from the alias to the real verb.
        let verbAliases: [String: String]

        /// The noun aliases of the tool, from the alias to the real noun.
        let nounAliases: [String: String]

        /// The operations of the tool.
        let operations: [AnyOperation<CodeContextToolContext>]
    }

    /// The tables of the three tools.
    private static let toolTables = [
        ToolTables(
            name: CodeSearchTool.name,
            verbAliases: CodeSearchTool.verbAliases,
            nounAliases: CodeSearchTool.nounAliases,
            operations: CodeSearchTool.operations()
        ),
        ToolTables(
            name: CodeNavigationTool.name,
            verbAliases: CodeNavigationTool.verbAliases,
            nounAliases: CodeNavigationTool.nounAliases,
            operations: CodeNavigationTool.operations()
        ),
        ToolTables(
            name: CodeIndexTool.name,
            verbAliases: CodeIndexTool.verbAliases,
            nounAliases: CodeIndexTool.nounAliases,
            operations: CodeIndexTool.operations()
        ),
    ]

    /// Indexes the fixture, makes the three tools, and gives them to `body`.
    ///
    /// - Parameter body: The test body.
    /// - Throws: The error that the setup or `body` throws.
    private static func withTools(_ body: ([any Tool]) async throws -> Void) async throws {
        try await ToolTest.withStartedContext(
            source: fixtureSource,
            file: fixtureFile,
            embeddingDimension: embeddingDimension
        ) { context in
            try await body(try CodeContextTools.make(context: context))
        }
    }

    /// Makes a parameter name comparable, as the resolver makes it: all
    /// lowercase, with no `_` and no `-`.
    ///
    /// - Parameter name: A parameter name, or an alias of one.
    /// - Returns: The comparable form of `name`.
    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0 != "_" && $0 != "-" }
    }

    // MARK: - The factory

    @Test
    func makeReturnsTheThreeNamedTools() async throws {
        try await Self.withTools { tools in
            #expect(tools.count == Self.toolCount)
            #expect(tools.map { $0.name } == CodeContextTools.toolNames)
            #expect(CodeContextTools.toolNames == ["code_search", "code_navigation", "code_index"])
        }
    }

    @Test
    func eachToolHasTheExpectedOperationCount() async throws {
        try await Self.withTools { tools in
            for tool in tools {
                let fused = try #require(tool as? OperationTool<CodeContextToolContext>)

                #expect(fused.operations.count == Self.expectedOperationCounts[fused.name], "tool: \(fused.name)")
            }
        }
    }

    @Test
    func operationNamesMatchTheTools() async throws {
        try await Self.withTools { tools in
            #expect(CodeContextTools.operationNames.count == Self.toolCount)

            for tool in tools {
                let fused = try #require(tool as? OperationTool<CodeContextToolContext>)

                #expect(
                    CodeContextTools.operationNames[fused.name] == fused.operations.map(\.opString),
                    "tool: \(fused.name)"
                )
            }
        }
    }

    @Test
    func toolsCanBeRegisteredOnALanguageModelSession() async throws {
        try await Self.withTools { tools in
            let session = LanguageModelSession(tools: tools, instructions: Self.sessionInstructions)

            #expect(session.transcript.isEmpty == false)
        }
    }

    // MARK: - The alias tables

    @Test
    func aliasTablesAreSafe() {
        for tables in Self.toolTables {
            let verbs = Set(tables.operations.map(\.verb))
            let nouns = Set(tables.operations.map(\.noun))

            for (alias, verb) in tables.verbAliases {
                #expect(verbs.contains(alias) == false, "\(tables.name): the verb alias `\(alias)` is a real verb")
                #expect(verbs.contains(verb), "\(tables.name): the verb alias `\(alias)` names no real verb")
            }
            for (alias, noun) in tables.nounAliases {
                #expect(nouns.contains(alias) == false, "\(tables.name): the noun alias `\(alias)` is a real noun")
                #expect(nouns.contains(noun), "\(tables.name): the noun alias `\(alias)` names no real noun")
            }
            for operation in tables.operations {
                Self.expectParameterAliasesAreSafe(of: operation, in: tables.name)
            }
        }
    }

    /// Expects that no alias of a parameter of `operation` normalizes to the
    /// name of another parameter, or to an alias of another parameter.
    ///
    /// Such an alias would make the resolver give the value to the wrong
    /// parameter. Two aliases of the same parameter cannot do this, because
    /// they both name that one parameter.
    ///
    /// - Parameters:
    ///   - operation: The operation to examine.
    ///   - toolName: The name of the tool, for the message of a failure.
    private static func expectParameterAliasesAreSafe(
        of operation: AnyOperation<CodeContextToolContext>,
        in toolName: String
    ) {
        var ownerOfKey: [String: String] = [:]
        for parameter in operation.parameters {
            ownerOfKey[normalized(parameter.name)] = parameter.name
        }
        for parameter in operation.parameters {
            for alias in parameter.aliases {
                let owner = ownerOfKey[normalized(alias)]

                #expect(
                    owner == nil || owner == parameter.name,
                    "\(toolName) `\(operation.opString)`: the alias `\(alias)` of `\(parameter.name)` also names `\(owner ?? "")`"
                )
                ownerOfKey[normalized(alias)] = parameter.name
            }
        }
    }
}
