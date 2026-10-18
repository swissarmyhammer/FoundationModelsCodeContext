import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `LanguageServerDocument`: the one path check, disk read and URI
/// build that each caller makes before it syncs a document to a language
/// server.
struct LanguageServerDocumentTests {
    /// The path of a fixture file that the path filter accepts.
    private static let keptPath = "Kept.swift"

    /// The path of a fixture file in a hard-skip directory, thus the path
    /// filter does not accept it, also with no rule file.
    private static let skippedPath = "node_modules/Skipped.swift"

    /// The text of each fixture source file.
    private static let swiftSource = "func kept() {}\n"

    /// Bytes that are not UTF-8 text.
    private static let notUTF8 = Data([0xFF, 0xFE, 0xFD])

    @Test
    func anAcceptedFileGivesItsURIAndItsDiskText() async throws {
        try await withTemporaryWorkspace { root in
            try write(Self.swiftSource, to: Self.keptPath, in: root)

            let document = LanguageServerDocument(relativePath: Self.keptPath, rootDirectory: root, pathFilter: PathFilter(rootDirectory: root))

            #expect(document?.uri == DocumentURI(root.appendingPathComponent(Self.keptPath).absoluteString))
            #expect(document?.text == Self.swiftSource)
        }
    }

    @Test
    func aPathThatTheFilterDoesNotAcceptGivesNoDocument() async throws {
        try await withTemporaryWorkspace { root in
            try write(Self.swiftSource, to: Self.skippedPath, in: root)

            let document = LanguageServerDocument(relativePath: Self.skippedPath, rootDirectory: root, pathFilter: PathFilter(rootDirectory: root))

            #expect(document == nil)
        }
    }

    @Test
    func aFileThatIsNotUTF8GivesADocumentWithNoText() async throws {
        try await withTemporaryWorkspace { root in
            try Self.notUTF8.write(to: root.appendingPathComponent(Self.keptPath))

            let document = LanguageServerDocument(relativePath: Self.keptPath, rootDirectory: root, pathFilter: PathFilter(rootDirectory: root))

            #expect(document != nil)
            #expect(document?.text == nil)
        }
    }

    @Test
    func readTextRejectsAPathThatIsNotSafe() async throws {
        try await withTemporaryWorkspace { root in
            try write(Self.swiftSource, to: Self.keptPath, in: root)
            let unsafePath = "../" + root.lastPathComponent + "/" + Self.keptPath

            #expect(LanguageServerDocument.readText(relativePath: unsafePath, rootDirectory: root) == nil)
        }
    }

    @Test
    func theSharedFilterGivesTheSameDocument() async throws {
        try await withTemporaryWorkspace { root in
            try write(Self.swiftSource, to: Self.keptPath, in: root)
            let pathFilter = SharedPathFilter(rootDirectory: root)

            let document = await pathFilter.acceptedDocument(relativePath: Self.keptPath, rootDirectory: root)
            let skipped = await pathFilter.acceptedDocument(relativePath: Self.skippedPath, rootDirectory: root)

            #expect(document?.text == Self.swiftSource)
            #expect(skipped == nil)
        }
    }
}
