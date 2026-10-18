import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `RootDiscovery`: finding git-repo roots under a parent
/// directory (sibling repos, nested-repo pruning, `.git`-file worktrees,
/// git-only scope, hidden/symlink skipping) and resolving the enclosing
/// repo root for an arbitrary path.
struct RootDiscoveryTests {
    @Test
    func discoversSiblingRepositoriesSortedByPath() async throws {
        try await withTemporaryWorkspace { root in
            try makeGitDirRepo(at: root.appendingPathComponent("repo-b"))
            try makeGitDirRepo(at: root.appendingPathComponent("repo-a"))

            let roots = try RootDiscovery.discoverRoots(under: root)

            #expect(
                roots == [
                    root.appendingPathComponent("repo-a").standardizedFileURL,
                    root.appendingPathComponent("repo-b").standardizedFileURL,
                ])
        }
    }

    @Test
    func prunesRepoNestedInsideAnotherRepo() async throws {
        try await withTemporaryWorkspace { root in
            let outer = root.appendingPathComponent("outer", isDirectory: true)
            try makeGitDirRepo(at: outer)
            try makeGitDirRepo(at: outer.appendingPathComponent("vendor/inner"))

            let roots = try RootDiscovery.discoverRoots(under: root)

            #expect(roots == [outer.standardizedFileURL])
        }
    }

    @Test
    func recognizesGitFileWorktreeAsRoot() async throws {
        try await withTemporaryWorkspace { root in
            let worktree = root.appendingPathComponent("worktree", isDirectory: true)
            try makeGitFileRepo(at: worktree)

            let roots = try RootDiscovery.discoverRoots(under: root)

            #expect(roots == [worktree.standardizedFileURL])
        }
    }

    @Test
    func excludesDirectoryWithProjectMarkerButNoGit() async throws {
        try await withTemporaryWorkspace { root in
            try write("[package]\nname = \"a\"", to: "not-a-repo/Cargo.toml", in: root)

            let roots = try RootDiscovery.discoverRoots(under: root)

            #expect(roots.isEmpty)
        }
    }

    @Test
    func skipsHiddenDirectoriesDuringTraversal() async throws {
        try await withTemporaryWorkspace { root in
            try makeGitDirRepo(at: root.appendingPathComponent(".hidden/repo"))

            let roots = try RootDiscovery.discoverRoots(under: root)

            #expect(roots.isEmpty)
        }
    }

    @Test
    func doesNotFollowSymlinksDuringTraversal() async throws {
        try await withTemporaryWorkspace { root in
            let actual = root.appendingPathComponent("actual", isDirectory: true)
            try makeGitDirRepo(at: actual)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("alias"), withDestinationURL: actual)

            let roots = try RootDiscovery.discoverRoots(under: root)

            #expect(roots == [actual.standardizedFileURL])
        }
    }

    @Test
    func gitRootResolvesDeepFilePathToEnclosingRepoRoot() async throws {
        try await withTemporaryWorkspace { root in
            let repo = root.appendingPathComponent("repo", isDirectory: true)
            try makeGitDirRepo(at: repo)
            try write("// swift", to: "repo/Sources/A/a.swift", in: root)

            let resolved = RootDiscovery.gitRoot(
                containing: repo.appendingPathComponent("Sources/A/a.swift"))

            #expect(resolved == repo.standardizedFileURL)
        }
    }

    @Test
    func gitRootReturnsNilOutsideAnyRepo() async throws {
        try await withTemporaryWorkspace { root in
            try write("hello", to: "plain/file.txt", in: root)

            let resolved = RootDiscovery.gitRoot(containing: root.appendingPathComponent("plain/file.txt"))

            #expect(resolved == nil)
        }
    }

    @Test
    func discoverRootsReturnsParentItselfWhenItIsARepo() async throws {
        try await withTemporaryWorkspace { root in
            try makeGitDirRepo(at: root)

            let roots = try RootDiscovery.discoverRoots(under: root)

            #expect(roots == [root.standardizedFileURL])
        }
    }

    @Test
    func gitRootOnRepoRootDirectoryReturnsItself() async throws {
        try await withTemporaryWorkspace { root in
            let repo = root.appendingPathComponent("repo")
            try makeGitDirRepo(at: repo)

            let resolved = RootDiscovery.gitRoot(containing: repo)

            #expect(resolved == repo.standardizedFileURL)
        }
    }

    @Test
    func discoverRootsThrowsForNonexistentParent() async throws {
        try await withTemporaryWorkspace { root in
            let missing = root.appendingPathComponent("does-not-exist")

            #expect(throws: (any Error).self) {
                try RootDiscovery.discoverRoots(under: missing)
            }
        }
    }
}

/// Creates `url` as a directory containing a `.git` **directory**,
/// mirroring a normal (non-worktree) git repository root.
private func makeGitDirRepo(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
}

/// Creates `url` as a directory containing a `.git` **file**, mirroring a
/// worktree or submodule's `gitdir:`-pointer style repo root.
private func makeGitFileRepo(at url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try "gitdir: /elsewhere/.git/worktrees/example".write(
        to: url.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
}
