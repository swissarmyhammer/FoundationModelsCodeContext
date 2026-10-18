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
    func relativeFilePathOfAURIWithTheRealPathBelowASymlinkedRootIsTheRelativeKey() async throws {
        try await withSymlinkedWorkspace { link, target in
            try write("fn a() {}", to: "src/a.rs", in: target)
            let uri = DocumentURI(try realPath(of: target.appendingPathComponent("src/a.rs")).absoluteString)

            #expect(WorkspaceRoot(link).relativeFilePath(fromURI: uri) == "src/a.rs")
        }
    }

    @Test
    func relativeFilePathOfAURIOutsideBothRootsIsTheFilePath() async throws {
        try await withSymlinkedWorkspace { link, _ in
            let outside = URL(fileURLWithPath: "/usr/include/stdio.h")

            #expect(WorkspaceRoot(link).relativeFilePath(fromURI: DocumentURI(outside.absoluteString)) == outside.path)
        }
    }

    @Test
    func relativeFilePathOfAURIThatIsNotAURLIsTheRawValue() async throws {
        try await withSymlinkedWorkspace { link, _ in
            let notAURL = DocumentURI("")

            #expect(WorkspaceRoot(link).relativeFilePath(fromURI: notAURL) == notAURL.value)
            #expect(WorkspaceRoot(link).relativePath(ofURI: notAURL) == nil)
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
        _ = CapturedLogRecords.handler
        try await withTemporaryWorkspace { root in
            let ruleFilePath = "unreadable-rules-\(UUID().uuidString)/.gitignore"
            try write("a.rs\n", to: ruleFilePath, in: root)
            let ruleFile = root.appendingPathComponent(ruleFilePath)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: ruleFile.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ruleFile.path) }

            #expect(throws: PathFilter.LoadError(relativePath: ruleFilePath)) {
                try PathFilter.load(rootDirectory: root)
            }
            let warnings = CapturedLogRecords.entries(matching: [CodeContextTracing.MetadataKey.filePath: ruleFilePath])
            #expect(
                warnings.map(\.message.description)
                    == ["the walk cannot read an ignore rule file and continues without its rules"]
            )
            #expect(warnings.allSatisfy { $0.level == .warning })
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

    // MARK: - Documents for the language servers

    @Test
    func aDocumentInTheRootIsAccepted() async throws {
        try await withTemporaryWorkspace { root in
            try write("struct A {}\n", to: "src/a.swift", in: root)
            let filter = PathFilter(rootDirectory: root)

            #expect(filter.acceptsDocument(relativePath: "src/a.swift"))
        }
    }

    @Test
    func aDocumentInASymlinkedRootIsAccepted() async throws {
        try await withSymlinkedWorkspace { link, target in
            try write("struct A {}\n", to: "src/a.swift", in: target)
            let filter = PathFilter(rootDirectory: link)

            #expect(filter.acceptsDocument(relativePath: "src/a.swift"))
        }
    }

    @Test
    func aDocumentThatTheRulesIgnoreIsNotAccepted() async throws {
        try await withTemporaryWorkspace { root in
            try write("build-out/\n", to: ".gitignore", in: root)
            try write("struct Generated {}\n", to: "build-out/Generated.swift", in: root)
            try write("struct Hidden {}\n", to: ".hidden/Hidden.swift", in: root)
            let filter = try PathFilter.load(rootDirectory: root)

            #expect(!filter.acceptsDocument(relativePath: "build-out/Generated.swift"))
            #expect(!filter.acceptsDocument(relativePath: ".hidden/Hidden.swift"))
        }
    }

    @Test
    func aPathThatIsNotASafeRelativePathIsNotAccepted() async throws {
        try await withTemporaryWorkspace { root in
            try write("struct A {}\n", to: "src/a.swift", in: root)
            let filter = PathFilter(rootDirectory: root)

            for unsafePath in ["../a.swift", "src/../../a.swift", "/etc/hosts", "~/a.swift", ""] {
                #expect(!filter.acceptsDocument(relativePath: unsafePath), "\(unsafePath)")
            }
        }
    }

    @Test
    func aSymbolicLinkThatPointsOutOfTheRootIsNotAccepted() async throws {
        try await withTemporaryWorkspace { root in
            try await withTemporaryWorkspace { outside in
                try writeLinkOutOfRoot("struct Secret {}\n", at: "src/Secret.swift", in: root, outside: outside)
                try FileManager.default.createSymbolicLink(
                    at: root.appendingPathComponent("vendor"),
                    withDestinationURL: outside
                )
                try write("struct Vendored {}\n", to: "Vendored.swift", in: outside)
                let filter = PathFilter(rootDirectory: root)

                #expect(!filter.acceptsDocument(relativePath: "src/Secret.swift"))
                #expect(!filter.acceptsDocument(relativePath: "vendor/Vendored.swift"))
            }
        }
    }

    @Test
    func aSymbolicLinkThatPointsInTheRootIsAccepted() async throws {
        try await withTemporaryWorkspace { root in
            try write("struct A {}\n", to: "src/a.swift", in: root)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("Alias.swift"),
                withDestinationURL: root.appendingPathComponent("src/a.swift")
            )
            let filter = PathFilter(rootDirectory: root)

            #expect(filter.acceptsDocument(relativePath: "Alias.swift"))
        }
    }

    @Test
    func aDocumentThatDoesNotExistIsNotAccepted() async throws {
        try await withTemporaryWorkspace { root in
            let filter = PathFilter(rootDirectory: root)

            #expect(!filter.acceptsDocument(relativePath: "src/Missing.swift"))
        }
    }

    @Test
    func theSharedFilterUsesTheRulesOfItsLastLoad() async throws {
        try await withTemporaryWorkspace { root in
            try write("struct Generated {}\n", to: "build-out/Generated.swift", in: root)
            let sharedFilter = SharedPathFilter(rootDirectory: root)
            #expect(await sharedFilter.acceptsDocument(relativePath: "build-out/Generated.swift"))

            try write("build-out/\n", to: ".gitignore", in: root)
            await sharedFilter.reload()

            #expect(await !sharedFilter.acceptsDocument(relativePath: "build-out/Generated.swift"))
        }
    }
}
