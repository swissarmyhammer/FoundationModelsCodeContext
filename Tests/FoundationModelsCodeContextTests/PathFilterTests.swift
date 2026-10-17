import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `WorkspaceRoot` and `PathFilter`: the one relative-path function
/// (the root, then the canonical root), the ancestor-directory ignore check,
/// the hard skips, and the rule load failure.
struct PathFilterTests {
    @Test
    func relativePathRemovesTheRootAndThenTheCanonicalRoot() async throws {
        try await withSymlinkedWorkspace { link, target in
            try write("fn a() {}", to: "src/a.rs", in: target)
            let root = WorkspaceRoot(link)

            #expect(root.relativePath(of: link.appendingPathComponent("src/a.rs")) == "src/a.rs")
            #expect(root.relativePath(of: try realPath(of: target.appendingPathComponent("src/a.rs"))) == "src/a.rs")
        }
    }

    @Test
    func relativePathOfAPathOutsideBothRootsIsNil() async throws {
        try await withSymlinkedWorkspace { link, _ in
            let root = WorkspaceRoot(link)

            #expect(root.relativePath(of: URL(fileURLWithPath: "/usr/include/stdio.h")) == nil)
            #expect(root.relativePath(of: link) == nil)
        }
    }

    @Test
    func aPathThatTheFilterCannotExamineIsIgnored() async throws {
        try await withTemporaryWorkspace { root in
            let filter = PathFilter(rootDirectory: root)

            #expect(filter.isIgnored(URL(fileURLWithPath: "/usr/include/stdio.h"), isDirectory: false))
        }
    }

    @Test
    func theHardSkipAndHiddenRulesApplyWithNoRuleFile() async throws {
        try await withTemporaryWorkspace { root in
            let filter = PathFilter(rootDirectory: root)

            for skipped in ["target/debug/a.rs", "node_modules/x/a.ts", ".build/a.swift", ".sah/a.rs", ".hidden/a.rs", "src/.a.rs"] {
                #expect(filter.isIgnored(root.appendingPathComponent(skipped), isDirectory: false), "\(skipped)")
            }
            #expect(!filter.isIgnored(root.appendingPathComponent("src/a.rs"), isDirectory: false))
        }
    }

    @Test
    func aDirectoryRuleIgnoresEachFileBelowTheDirectory() async throws {
        try await withTemporaryWorkspace { root in
            try write("build-out/\n/dist\n", to: ".gitignore", in: root)

            let filter = try PathFilter.load(rootDirectory: root)

            #expect(filter.isIgnored(root.appendingPathComponent("build-out/a/b.swift"), isDirectory: false))
            #expect(filter.isIgnored(root.appendingPathComponent("src/build-out/b.swift"), isDirectory: false))
            #expect(filter.isIgnored(root.appendingPathComponent("dist/d.rs"), isDirectory: false))
            #expect(!filter.isIgnored(root.appendingPathComponent("src/dist/e.rs"), isDirectory: false))
        }
    }

    @Test
    func loadThrowsWhenARuleFileCannotBeRead() async throws {
        try await withTemporaryWorkspace { root in
            try write("a.rs\n", to: ".gitignore", in: root)
            let ruleFile = root.appendingPathComponent(".gitignore")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: ruleFile.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ruleFile.path) }

            #expect(throws: PathFilter.LoadError.self) {
                try PathFilter.load(rootDirectory: root)
            }
        }
    }

    @Test
    func aRuleFileChangeIsFoundOnlyOutsideAnIgnoredDirectory() async throws {
        try await withTemporaryWorkspace { root in
            try write("node_modules/\n", to: ".gitignore", in: root)
            let filter = try PathFilter.load(rootDirectory: root)

            #expect(filter.isRuleFileChange(root.appendingPathComponent(".gitignore")))
            #expect(filter.isRuleFileChange(root.appendingPathComponent("src/.ignore")))
            #expect(filter.isRuleFileChange(root.appendingPathComponent(".git/info/exclude")))
            #expect(!filter.isRuleFileChange(root.appendingPathComponent("node_modules/x/.gitignore")))
            #expect(!filter.isRuleFileChange(root.appendingPathComponent("src/a.rs")))
        }
    }
}
