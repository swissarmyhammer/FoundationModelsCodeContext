import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `LanguageServerDocument`: the one path check, URI build and disk
/// read that each caller makes before it syncs a document to a language
/// server.
struct LanguageServerDocumentTests {
    /// The path of a fixture file that the path filter accepts.
    private static let keptPath = "Kept.swift"

    /// The path of a fixture file in a hard-skip directory, thus the path
    /// filter does not accept it, also with no rule file.
    private static let skippedPath = "node_modules/Skipped.swift"

    /// The text of each fixture source file.
    private static let swiftSource = "func kept() {}\n"

    /// The text that a test writes after it makes the document.
    private static let changedSource = "func changed() {}\n"

    /// Bytes that are not UTF-8 text.
    private static let notUTF8 = Data([0xFF, 0xFE, 0xFD])

    /// The POSIX permissions of a file that no process can read.
    private static let noAccess: Int16 = 0o000

    /// The POSIX permissions that let the owner read and write a file.
    private static let ownerReadWrite: Int16 = 0o600

    @Test
    func anAcceptedFileGivesItsURIAndItsDiskText() async throws {
        try await withTemporaryWorkspace { root in
            try write(Self.swiftSource, to: Self.keptPath, in: root)

            let document = try #require(
                LanguageServerDocument(relativePath: Self.keptPath, rootDirectory: root, pathFilter: PathFilter(rootDirectory: root))
            )

            #expect(document.uri == DocumentURI(root.appendingPathComponent(Self.keptPath).absoluteString))
            #expect(document.readText() == Self.swiftSource)
        }
    }

    @Test
    func readTextGivesTheDiskTextAtTheTimeOfTheCall() async throws {
        try await withTemporaryWorkspace { root in
            try write(Self.swiftSource, to: Self.keptPath, in: root)
            let document = try #require(
                LanguageServerDocument(relativePath: Self.keptPath, rootDirectory: root, pathFilter: PathFilter(rootDirectory: root))
            )

            try write(Self.changedSource, to: Self.keptPath, in: root)

            #expect(document.readText() == Self.changedSource)
        }
    }

    @Test
    func initNeedsNoReadAccessToTheFile() async throws {
        try await withTemporaryWorkspace { root in
            try write(Self.swiftSource, to: Self.keptPath, in: root)
            let filePath = root.appendingPathComponent(Self.keptPath).path
            try FileManager.default.setAttributes([.posixPermissions: Self.noAccess], ofItemAtPath: filePath)
            defer { try? FileManager.default.setAttributes([.posixPermissions: Self.ownerReadWrite], ofItemAtPath: filePath) }

            let document = LanguageServerDocument(relativePath: Self.keptPath, rootDirectory: root, pathFilter: PathFilter(rootDirectory: root))

            try #require(
                LanguageServerDocument.readText(relativePath: Self.keptPath, rootDirectory: root) == nil,
                "the test needs a file that the process cannot read"
            )
            #expect(document?.uri == LanguageServerDocument.uri(relativePath: Self.keptPath, rootDirectory: root))
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

            let document = try #require(
                LanguageServerDocument(relativePath: Self.keptPath, rootDirectory: root, pathFilter: PathFilter(rootDirectory: root))
            )

            #expect(document.readText() == nil)
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
    func theSharedFilterGivesTheSameDocumentAsThePathFilter() async throws {
        try await withTemporaryWorkspace { root in
            try write(Self.swiftSource, to: Self.keptPath, in: root)
            let sharedFilter = SharedPathFilter(rootDirectory: root)
            let expected = try #require(
                LanguageServerDocument(relativePath: Self.keptPath, rootDirectory: root, pathFilter: PathFilter(rootDirectory: root))
            )

            let document = try #require(await sharedFilter.acceptedDocument(relativePath: Self.keptPath, rootDirectory: root))

            #expect(document.uri == expected.uri)
            #expect(document.relativePath == expected.relativePath)
            #expect(document.rootDirectory == expected.rootDirectory)
        }
    }

    @Test
    func theSharedFilterGivesNoDocumentForAPathThatThePathFilterDoesNotAccept() async throws {
        try await withTemporaryWorkspace { root in
            try write(Self.swiftSource, to: Self.skippedPath, in: root)
            let sharedFilter = SharedPathFilter(rootDirectory: root)

            let skipped = await sharedFilter.acceptedDocument(relativePath: Self.skippedPath, rootDirectory: root)

            #expect(skipped == nil)
        }
    }
}
