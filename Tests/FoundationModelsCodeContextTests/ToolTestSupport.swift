import Foundation
import FoundationModels
import Operations
import Testing

@testable import FoundationModelsCodeContext

/// The shared helpers of the FoundationModels tool tests.
///
/// Each tool test indexes a small fixture, makes its tool, and calls the tool
/// as the model calls it. These helpers hold that shared work, so each suite
/// gives only its own fixture and its own tool factory.
enum ToolTest {
    /// One tool call, and the JSON text that the call must give.
    typealias Call = (arguments: GeneratedContent, expected: String)

    /// The process identifier of the fake language-server connection.
    private static let fakeProcessIdentifier: Int32 = 1

    /// Indexes one fixture file in a new temporary workspace and gives the
    /// started `CodeContext` to `body`.
    ///
    /// The workspace has no project marker, so no LSP daemon starts, and the
    /// tree-sitter layer answers each operation. The `CodeContext` stops after
    /// `body`, also when `body` throws.
    ///
    /// - Parameters:
    ///   - source: The text of the fixture file.
    ///   - file: The path of the fixture file, relative to the workspace root.
    ///   - embeddingDimension: The dimension of the fake embedding vectors.
    ///   - body: The test body.
    /// - Throws: The error that the setup or `body` throws.
    static func withStartedContext(
        source: String,
        file: String,
        embeddingDimension: Int,
        _ body: (CodeContext<FakeLanguageServerConnection>) async throws -> Void
    ) async throws {
        try await withTemporaryWorkspace { root in
            try write(source, to: file, in: root)
            let context = try await CodeContext<FakeLanguageServerConnection>(
                rootDirectory: root,
                embedder: FakeEmbedder(dimension: embeddingDimension),
                eventSource: FakeFileEventSource(),
                autoInstall: LspAutoInstall(isEnabled: false),
                connectionFactory: fakeConnectionFactory(pid: fakeProcessIdentifier, processState: ProcessState())
            )
            try await context.start()
            do {
                try await body(context)
            } catch {
                await context.stop()
                throw error
            }
            await context.stop()
        }
    }

    /// Indexes one fixture file in a new temporary workspace, makes the tool,
    /// and gives the tool and the `CodeContext` to `body`.
    ///
    /// The setup is the setup of `withStartedContext(source:file:embeddingDimension:_:)`.
    ///
    /// - Parameters:
    ///   - source: The text of the fixture file.
    ///   - file: The path of the fixture file, relative to the workspace root.
    ///   - embeddingDimension: The dimension of the fake embedding vectors.
    ///   - make: Makes the tool from the tool context.
    ///   - body: The test body.
    /// - Throws: The error that the setup or `body` throws.
    static func withIndexedTool(
        source: String,
        file: String,
        embeddingDimension: Int,
        make: (CodeContextToolContext) throws -> OperationTool<CodeContextToolContext>,
        _ body: (OperationTool<CodeContextToolContext>, CodeContext<FakeLanguageServerConnection>) async throws -> Void
    ) async throws {
        try await withStartedContext(source: source, file: file, embeddingDimension: embeddingDimension) { context in
            try await body(try make(CodeContextToolContext(operating: context)), context)
        }
    }

    /// Calls `tool` with the arguments of each call, and expects the JSON
    /// text of that call.
    ///
    /// - Parameters:
    ///   - calls: The tool calls and their expected JSON text.
    ///   - tool: The tool to call.
    /// - Throws: The error that the tool throws.
    static func expectEachCall(_ calls: [Call], on tool: OperationTool<CodeContextToolContext>) async throws {
        for call in calls {
            let output = try await tool.call(arguments: call.arguments)
            #expect(output == call.expected, "arguments: \(call.arguments.jsonString)")
        }
    }

    /// Decodes a tool output that is one JSON string, for example a corrective
    /// message of an operation.
    ///
    /// - Parameter output: The tool output.
    /// - Returns: The decoded string.
    /// - Throws: A `DecodingError` when `output` is not one JSON string.
    static func decodedString(_ output: String) throws -> String {
        try JSONDecoder().decode(String.self, from: Data(output.utf8))
    }
}
