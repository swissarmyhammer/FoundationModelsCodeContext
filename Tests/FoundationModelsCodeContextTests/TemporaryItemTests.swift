import Foundation
import Testing

/// Tests for `TemporaryItem`: each temporary item of the test target is below
/// one shared directory, and that directory is not below `$TMPDIR`.
///
/// A path lookup through a `$TMPDIR` that holds very many entries can take
/// seconds. The parallel tests then block each thread of the cooperative
/// pool, and the tests that measure time fail. These tests make sure that the
/// shared fixtures do not put items below `$TMPDIR`.
struct TemporaryItemTests {
    @Test
    func theSharedDirectoryIsNotBelowTheTemporaryDirectoryOfTheUser() {
        let userTemporaryPath = FileManager.default.temporaryDirectory.standardizedFileURL.path

        #expect(!TemporaryItem.root.standardizedFileURL.path.hasPrefix(userTemporaryPath))
    }

    @Test
    func aTemporaryWorkspaceIsBelowTheSharedDirectory() async throws {
        let parent = try await withTemporaryWorkspace { root in
            root.deletingLastPathComponent()
        }

        #expect(parent.standardizedFileURL == TemporaryItem.root.standardizedFileURL)
    }

    @Test
    func theLinkOfASymlinkedWorkspaceIsBelowTheSharedDirectory() async throws {
        let parent = try await withSymlinkedWorkspace { link, _ in
            link.deletingLastPathComponent()
        }

        #expect(parent.standardizedFileURL == TemporaryItem.root.standardizedFileURL)
    }

    @Test
    func eachNewURLIsUniqueAndBelowTheSharedDirectory() {
        let first = TemporaryItem.makeURL(prefix: "unique")
        let second = TemporaryItem.makeURL(prefix: "unique")

        #expect(first != second)
        #expect(first.deletingLastPathComponent().standardizedFileURL == TemporaryItem.root.standardizedFileURL)
        #expect(first.lastPathComponent.hasPrefix("unique-"))
    }
}
