import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests the index fallback of `definition` at a call site.
///
/// With no language server, the index answers. At a call `helper()` inside
/// `user()`, the symbol that encloses the cursor is `user`: a wrong answer
/// that a model trusts. The fallback therefore resolves the name at the
/// cursor, and never gives the enclosing function for a call site.
struct DefinitionByNameTests {
    /// The dimension of the fake embedding vectors.
    private static let embeddingDimension = 8

    /// `helper` and `user`, where `user` calls `helper`.
    private static let libSource = """
        def helper():
            return "hello"


        def user():
            return helper()
        """

    /// A second module that imports `helper` from `lib` and calls it, and
    /// calls a name that no file defines.
    private static let viewsSource = """
        from lib import helper


        def view():
            helper()
            return missing()
        """

    /// A third module with its own `helper`, which no other file imports. Its
    /// name sorts before `lib.py`, so only the import rank puts `lib.py` first.
    private static let altSource = """
        def helper():
            return "alt"
        """

    /// A module that imports `lib` and calls `lib.helper()`.
    private static let appSource = """
        import lib


        def run():
            return lib.helper()
        """

    /// Starts a `CodeContext` on the four files, with no language server,
    /// and gives it to `body`.
    private static func withIndexedFiles(
        _ body: (CodeContext<FakeLanguageServerConnection>) async throws -> Void
    ) async throws {
        try await withTemporaryWorkspace { root in
            try write(libSource, to: "lib.py", in: root)
            try write(viewsSource, to: "views.py", in: root)
            try write(altSource, to: "alt.py", in: root)
            try write(appSource, to: "app.py", in: root)
            try await ToolTest.withStartedContext(rootDirectory: root, embeddingDimension: embeddingDimension, body)
        }
    }

    @Test
    func definitionAtACallGivesTheCalledFunctionNotTheEnclosingOne() async throws {
        try await Self.withIndexedFiles { context in
            let result = try await context.definition(filePath: "lib.py", line: 5, character: 11)

            let first = try #require(result.locations.first)
            #expect(first.filePath == "lib.py")
            #expect(first.range.start.line == 0)
            #expect(first.symbol?.name == "helper")
            #expect(!result.locations.contains { $0.symbol?.name == "user" })
            #expect(result.resolvedBy == "name")
            #expect(result.note?.contains("helper") == true)
        }
    }

    @Test
    func anImportedNameRanksTheImportedModuleBeforeTheOthers() async throws {
        try await Self.withIndexedFiles { context in
            let result = try await context.definition(filePath: "views.py", line: 4, character: 4)

            #expect(result.locations.map(\.filePath) == ["lib.py", "alt.py"])
            #expect(result.resolvedBy == "name")
        }
    }

    @Test
    func aQualifiedCallRanksTheModuleOfTheQualifierFirst() async throws {
        try await Self.withIndexedFiles { context in
            let result = try await context.definition(filePath: "app.py", line: 4, character: 15)

            #expect(result.locations.map(\.filePath) == ["lib.py", "alt.py"])
            #expect(result.note?.contains("2 definitions") == true)
        }
    }

    @Test
    func aNameThatNoFileDefinesGivesNoLocationAndANote() async throws {
        try await Self.withIndexedFiles { context in
            let result = try await context.definition(filePath: "views.py", line: 5, character: 11)

            #expect(result.locations.isEmpty)
            #expect(result.note?.contains("missing") == true)
        }
    }

    @Test
    func theDefiningNameKeepsItsOwnDefinition() async throws {
        try await Self.withIndexedFiles { context in
            let result = try await context.definition(filePath: "lib.py", line: 0, character: 4)

            #expect(result.locations.first?.symbol?.name == "helper")
            #expect(result.locations.first?.filePath == "lib.py")
            #expect(result.resolvedBy == nil)
        }
    }
}
