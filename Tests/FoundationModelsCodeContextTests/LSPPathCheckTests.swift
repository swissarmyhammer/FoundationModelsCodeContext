import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the path check before `textDocument/didOpen`: the LSP index
/// worker, the live operations and the diagnostics operation use the shared
/// path filter, thus they do not open a path that the ignore rules ignore or a
/// path whose real path is not in the workspace root.
///
/// Each test uses `FakeLanguageServerConnection` and examines the calls that
/// the connection records.
struct LSPPathCheckTests {
    /// The rule file text that ignores the `build-out/` directory.
    private static let buildOutRule = "build-out/\n"

    /// The path of a file that `buildOutRule` ignores.
    private static let ignoredPath = "build-out/Generated.swift"

    /// The path of the symbolic link that points out of the root.
    private static let linkPath = "Linked.swift"

    /// The text of each fixture source file.
    private static let swiftSource = "func generated() {}\n"

    /// The settle window of the diagnostics tests. It is short, because the
    /// fake connection sends no diagnostics.
    private static let settleWindow: Duration = .milliseconds(1)

    /// The hard timeout of the diagnostics tests.
    private static let hardTimeout: Duration = .milliseconds(20)

    /// Gives the document uris that `connection` got a `didOpen` for.
    /// - Parameter connection: The fake connection.
    /// - Returns: The uris, in call order.
    private static func openedURIs(_ connection: FakeLanguageServerConnection) async -> [DocumentURI] {
        await connection.calls.compactMap { call in
            guard case .didOpen(let uri, _, _, _) = call else {
                return nil
            }
            return uri
        }
    }

    /// Gives the document uris that `connection` got a pull-diagnostics
    /// request for.
    /// - Parameter connection: The fake connection.
    /// - Returns: The uris, in call order.
    private static func pulledURIs(_ connection: FakeLanguageServerConnection) async -> [DocumentURI] {
        await connection.calls.compactMap { call in
            guard case .pullDiagnostics(let uri) = call else {
                return nil
            }
            return uri
        }
    }

    /// Writes the `build-out/` rule and the ignored file, and gives a shared
    /// filter that loaded the rule.
    /// - Parameter root: The workspace root.
    /// - Returns: The shared filter of the workspace.
    /// - Throws: The error of a write.
    private static func makeIgnoredFixture(root: URL) async throws -> SharedPathFilter {
        try write(buildOutRule, to: ".gitignore", in: root)
        try write(swiftSource, to: ignoredPath, in: root)
        let pathFilter = SharedPathFilter(rootDirectory: root)
        await pathFilter.reload()
        return pathFilter
    }

    /// Marks `filePath` dirty in each layer.
    /// - Parameters:
    ///   - store: The store of the workspace.
    ///   - filePath: The path of the file, relative to the root.
    /// - Throws: The error of the store.
    private static func seedDirty(store: Store, filePath: String) async throws {
        try await store.markDirty(filePath: filePath, contentHash: Data(filePath.utf8), fileSize: 1)
    }

    /// Runs one drain of the Swift files through `session`.
    /// - Parameters:
    ///   - store: The store of the workspace.
    ///   - root: The workspace root.
    ///   - pathFilter: The shared filter of the workspace.
    ///   - session: The session over the fake connection.
    /// - Returns: The number of files that are now LSP-indexed.
    /// - Throws: The error of the dirty-file query.
    @discardableResult
    private static func drainSwift(
        store: Store,
        root: URL,
        pathFilter: SharedPathFilter,
        session: LspSession<FakeLanguageServerConnection>
    ) async throws -> Int {
        try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
            store: store, rootDirectory: root, pathFilter: pathFilter, extensions: ["swift"], session: session
        )
    }

    /// Runs the diagnostics operation for one file, with no dependents.
    /// - Parameters:
    ///   - filePath: The file to diagnose, relative to the root.
    ///   - root: The workspace root.
    ///   - pathFilter: The shared filter of the workspace.
    ///   - session: The session over the fake connection.
    /// - Throws: The error of the operation.
    private static func diagnose(
        _ filePath: String,
        root: URL,
        pathFilter: SharedPathFilter,
        session: LspSession<FakeLanguageServerConnection>
    ) async throws {
        _ = try await DiagnosticsOps<FakeLanguageServerConnection>.diagnostics(
            store: try Store(rootDirectory: root),
            session: session,
            rootDirectory: root,
            pathFilter: pathFilter,
            scope: .file(filePath),
            includeDependents: false,
            settleWindow: settleWindow,
            hardTimeout: hardTimeout
        )
    }

    // MARK: - LSP index worker

    @Test
    func theWorkerDoesNotOpenAnIgnoredDirtyFile() async throws {
        try await withTemporaryWorkspace { root in
            let pathFilter = try await Self.makeIgnoredFixture(root: root)
            let store = try Store(rootDirectory: root)
            try await Self.seedDirty(store: store, filePath: Self.ignoredPath)
            let connection = FakeLanguageServerConnection()
            let session = LspSession(connection: connection, languageID: "swift")

            try await Self.drainSwift(store: store, root: root, pathFilter: pathFilter, session: session)

            #expect(await Self.openedURIs(connection).isEmpty)
        }
    }

    @Test
    func theWorkerMarksAnIgnoredDirtyFileIndexedAndDoesNotSelectItAgain() async throws {
        try await withTemporaryWorkspace { root in
            let pathFilter = try await Self.makeIgnoredFixture(root: root)
            let store = try Store(rootDirectory: root)
            try await Self.seedDirty(store: store, filePath: Self.ignoredPath)
            let session = LspSession(connection: FakeLanguageServerConnection(), languageID: "swift")

            try await Self.drainSwift(store: store, root: root, pathFilter: pathFilter, session: session)
            let secondPassCount = try await Self.drainSwift(store: store, root: root, pathFilter: pathFilter, session: session)

            #expect(try await store.drainLspDirty().isEmpty)
            #expect(secondPassCount == 0)
        }
    }

    @Test
    func theWorkerDoesNotOpenASymbolicLinkThatPointsOutOfTheRoot() async throws {
        try await withTemporaryWorkspace { root in
            try await withTemporaryWorkspace { outside in
                try writeLinkOutOfRoot(Self.swiftSource, at: Self.linkPath, in: root, outside: outside)
                let store = try Store(rootDirectory: root)
                try await Self.seedDirty(store: store, filePath: Self.linkPath)
                let connection = FakeLanguageServerConnection()
                let session = LspSession(connection: connection, languageID: "swift")

                try await Self.drainSwift(
                    store: store, root: root, pathFilter: SharedPathFilter(rootDirectory: root), session: session
                )

                #expect(await Self.openedURIs(connection).isEmpty)
                #expect(try await store.drainLspDirty().isEmpty)
            }
        }
    }

    @Test
    func theReferencesFallbackDoesNotOpenAnIgnoredFileThatHoldsAReference() async throws {
        try await withTemporaryWorkspace { root in
            try write(Self.buildOutRule, to: ".gitignore", in: root)
            try write("def helper():\n    return 1\n", to: "sample.py", in: root)
            try write("def caller():\n    return helper()\n", to: "build-out/caller.py", in: root)
            let pathFilter = SharedPathFilter(rootDirectory: root)
            await pathFilter.reload()
            let store = try Store(rootDirectory: root)
            try await Self.seedDirty(store: store, filePath: "sample.py")
            let connection = FakeLanguageServerConnection()
            let sampleURI = DocumentURI(root.appendingPathComponent("sample.py").absoluteString)
            let ignoredURI = DocumentURI(root.appendingPathComponent("build-out/caller.py").absoluteString)
            let helperRange = LSPRange(start: Position(line: 0, character: 0), end: Position(line: 1, character: 0))
            await connection.setDocumentSymbolsResult(
                .success([DocumentSymbol(name: "helper", detail: nil, kind: .function, range: helperRange, selectionRange: helperRange, children: nil)]),
                for: sampleURI
            )
            await connection.setReferencesResult(
                .success([Location(uri: ignoredURI, range: LSPRange(start: Position(line: 1, character: 11), end: Position(line: 1, character: 17)))]),
                in: sampleURI,
                at: Position(line: 0, character: 4)
            )

            try await LSPIndexWorker<FakeLanguageServerConnection>.drainBatch(
                store: store, rootDirectory: root, pathFilter: pathFilter, extensions: ["py"], session: LspSession.makePylsp(over: connection)
            )

            #expect(await Self.openedURIs(connection) == [sampleURI])
        }
    }

    // MARK: - Live operations

    @Test
    func aLiveOperationDoesNotOpenAnIgnoredFile() async throws {
        try await withTemporaryWorkspace { root in
            let pathFilter = try await Self.makeIgnoredFixture(root: root)
            let connection = FakeLanguageServerConnection()

            _ = try await LiveOpsCore<FakeLanguageServerConnection>.hover(
                store: try Store(rootDirectory: root),
                session: LspSession(connection: connection, languageID: "swift"),
                rootDirectory: root,
                pathFilter: pathFilter,
                filePath: Self.ignoredPath,
                line: 0,
                character: 5
            )

            #expect(await Self.openedURIs(connection).isEmpty)
        }
    }

    @Test
    func aLiveOperationDoesNotOpenASymbolicLinkThatPointsOutOfTheRoot() async throws {
        try await withTemporaryWorkspace { root in
            try await withTemporaryWorkspace { outside in
                try writeLinkOutOfRoot(Self.swiftSource, at: Self.linkPath, in: root, outside: outside)
                let connection = FakeLanguageServerConnection()

                _ = try await LiveOpsCore<FakeLanguageServerConnection>.hover(
                    store: try Store(rootDirectory: root),
                    session: LspSession(connection: connection, languageID: "swift"),
                    rootDirectory: root,
                    pathFilter: SharedPathFilter(rootDirectory: root),
                    filePath: Self.linkPath,
                    line: 0,
                    character: 5
                )

                #expect(await Self.openedURIs(connection).isEmpty)
            }
        }
    }

    // MARK: - Diagnostics

    @Test
    func diagnosticsDoesNotOpenOrPullAnIgnoredFile() async throws {
        try await withTemporaryWorkspace { root in
            let pathFilter = try await Self.makeIgnoredFixture(root: root)
            let connection = FakeLanguageServerConnection()

            try await Self.diagnose(
                Self.ignoredPath, root: root, pathFilter: pathFilter, session: LspSession(connection: connection, languageID: "swift")
            )

            #expect(await Self.openedURIs(connection).isEmpty)
            #expect(await Self.pulledURIs(connection).isEmpty)
        }
    }

    @Test
    func diagnosticsDoesNotOpenOrPullASymbolicLinkThatPointsOutOfTheRoot() async throws {
        try await withTemporaryWorkspace { root in
            try await withTemporaryWorkspace { outside in
                try writeLinkOutOfRoot(Self.swiftSource, at: Self.linkPath, in: root, outside: outside)
                let connection = FakeLanguageServerConnection()

                try await Self.diagnose(
                    Self.linkPath,
                    root: root,
                    pathFilter: SharedPathFilter(rootDirectory: root),
                    session: LspSession(connection: connection, languageID: "swift")
                )

                #expect(await Self.openedURIs(connection).isEmpty)
                #expect(await Self.pulledURIs(connection).isEmpty)
            }
        }
    }

    @Test
    func diagnosticsOpensAndPullsAnAcceptedFile() async throws {
        try await withTemporaryWorkspace { root in
            try write(Self.swiftSource, to: "Kept.swift", in: root)
            let connection = FakeLanguageServerConnection()
            let keptURI = DocumentURI(root.appendingPathComponent("Kept.swift").absoluteString)

            try await Self.diagnose(
                "Kept.swift",
                root: root,
                pathFilter: SharedPathFilter(rootDirectory: root),
                session: LspSession(connection: connection, languageID: "swift")
            )

            #expect(await Self.openedURIs(connection) == [keptURI])
            #expect(await Self.pulledURIs(connection) == [keptURI])
        }
    }
}
