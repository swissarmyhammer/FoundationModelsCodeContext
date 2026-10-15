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
    /// One tool call, and the expectation that its output must meet.
    typealias ExpectedCall<Expected> = (arguments: GeneratedContent, expected: Expected)

    /// One tool call, and the JSON text that the call must give.
    typealias Call = ExpectedCall<String>

    /// One tool call that gives a corrective message, and the key words that
    /// the message must hold.
    ///
    /// The key words are the parameter names and the scope names that the
    /// message must tell the model. A test that compares the message with the
    /// production text cannot fail, and a full copy of the text is a second
    /// copy to keep in sync. The key words fail the test when the message is
    /// broken or when it names a different parameter or scope.
    typealias CorrectiveCall = ExpectedCall<[String]>

    /// The process identifier of the fake language-server connection.
    private static let fakeProcessIdentifier: Int32 = 1

    /// Indexes one fixture file in a new temporary workspace and gives the
    /// started `CodeContext` to `body`.
    ///
    /// `start()` returns before the first index pass is complete. Thus this
    /// helper calls `waitForFirstIndexPass()` after `start()`, and `body`
    /// receives a `CodeContext` whose first index pass is complete.
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
            try await withStartedContext(rootDirectory: root, embeddingDimension: embeddingDimension, body)
        }
    }

    /// Starts a `CodeContext` on a workspace that the test prepared, and
    /// gives the `CodeContext` to `body` after its first index pass.
    ///
    /// Use this helper when a test must write more than one file, or must make
    /// a git repository, before the index pass. The workspace must have no
    /// project marker, so no LSP daemon starts. The `CodeContext` stops after
    /// `body`, also when `body` throws.
    ///
    /// - Parameters:
    ///   - root: The workspace root, with the files of the test in it.
    ///   - embeddingDimension: The dimension of the fake embedding vectors.
    ///   - body: The test body.
    /// - Throws: The error that the setup or `body` throws.
    static func withStartedContext(
        rootDirectory root: URL,
        embeddingDimension: Int,
        _ body: (CodeContext<FakeLanguageServerConnection>) async throws -> Void
    ) async throws {
        let context = try await CodeContext<FakeLanguageServerConnection>(
            rootDirectory: root,
            embedder: FakeEmbedder(vectorLength: embeddingDimension),
            eventSource: FakeFileEventSource(),
            autoInstall: LspAutoInstall(isEnabled: false),
            connectionFactory: fakeConnectionFactory(pid: fakeProcessIdentifier, processState: ProcessState())
        )
        try await context.start()
        await context.waitForFirstIndexPass()
        try await withAsyncCleanup {
            try await body(context)
        } cleanup: {
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

    /// Calls `tool` with the arguments of each call, and expects the JSON text
    /// of that call.
    ///
    /// - Parameters:
    ///   - calls: The tool calls and their expected JSON text.
    ///   - tool: The tool to call.
    /// - Throws: The error that the tool throws.
    static func expectEachCall(_ calls: [Call], on tool: OperationTool<CodeContextToolContext>) async throws {
        try await checkEachOutput(of: calls, on: tool) { output, expected, arguments in
            #expect(output == expected, "arguments: \(arguments.jsonString)")
        }
    }

    /// Calls `tool` with the arguments of each call, and expects a corrective
    /// message that holds each key word of that call.
    ///
    /// A corrective message is one JSON string. This helper decodes it with
    /// `decodedString(_:)`, and then checks the key words with
    /// `expectKeyWords(_:in:context:sourceLocation:)`.
    ///
    /// - Parameters:
    ///   - calls: The tool calls and the key words of their corrective
    ///     messages.
    ///   - tool: The tool to call.
    ///   - sourceLocation: The location of the caller, for a failure.
    /// - Throws: The error that the tool throws, or a `DecodingError` when an
    ///   output is not one JSON string.
    static func expectEachCorrectiveMessage(
        _ calls: [CorrectiveCall],
        on tool: OperationTool<CodeContextToolContext>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await checkEachOutput(of: calls, on: tool) { output, keyWords, arguments in
            expectKeyWords(
                keyWords,
                in: try decodedString(output),
                context: "arguments: \(arguments.jsonString)",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Expects that `message` holds each key word.
    ///
    /// - Parameters:
    ///   - keyWords: The words that `message` must hold, for example
    ///     "parameter `file`" and "scope `file`".
    ///   - message: The corrective message to examine.
    ///   - context: More text for a failure, for example the tool arguments.
    ///   - sourceLocation: The location of the caller, for a failure.
    static func expectKeyWords(
        _ keyWords: [String],
        in message: String,
        context: String = "",
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for keyWord in keyWords {
            #expect(
                message.contains(keyWord),
                "key word: \(keyWord), message: \(message) \(context)",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Calls `tool` with the arguments of each call, and gives each raw
    /// output to `check` with the expectation of its call.
    ///
    /// - Parameters:
    ///   - calls: The tool calls and their expectations.
    ///   - tool: The tool to call.
    ///   - check: Examines one output. It receives the raw output, the
    ///     expectation and the arguments of the call.
    /// - Throws: The error that the tool or `check` throws.
    private static func checkEachOutput<Expected>(
        of calls: [ExpectedCall<Expected>],
        on tool: OperationTool<CodeContextToolContext>,
        _ check: (String, Expected, GeneratedContent) throws -> Void
    ) async throws {
        for call in calls {
            let output = try await tool.call(arguments: call.arguments)
            try check(output, call.expected, call.arguments)
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
