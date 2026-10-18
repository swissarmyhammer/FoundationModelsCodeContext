import CryptoKit
import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// The error that a reader from `EntryTypeReaders.failing(for:)` throws for
/// the entry whose type it does not read.
private struct InducedEntryTypeError: Error {}

/// The entry type readers that the walker tests and the reconcile tests give
/// to the walk.
private enum EntryTypeReaders {
    /// Gives an entry type reader that fails for one entry and reads the real
    /// type of each other entry.
    /// - Parameter failingName: The last path component of the entry whose
    ///   type the reader does not read.
    /// - Returns: A reader that throws `InducedEntryTypeError` for
    ///   `failingName`, and otherwise gives the result of
    ///   `Walker.entryType(at:)`.
    static func failing(for failingName: String) -> Walker.EntryTypeReader {
        { url in
            guard url.lastPathComponent != failingName else {
                throw InducedEntryTypeError()
            }
            return try Walker.entryType(at: url)
        }
    }
}

/// A cause that makes the walk leave one entry unexamined, and the way a test
/// makes that cause occur.
///
/// The walker tests and the reconcile tests use one tree for each cause: one
/// blocked source file at or below the unexamined entry, and one kept source
/// file that the walk examines.
enum UnexaminedEntryCause: CaseIterable, CustomTestStringConvertible {
    /// A directory that the walk cannot list. A test removes its permissions.
    case unlistableDirectory

    /// A file that the walk cannot read for the hash. A test removes its
    /// permissions.
    case unreadableFile

    /// A file whose type the walk cannot read. A test gives the walk an entry
    /// type reader that fails for this file.
    case unreadableEntryType

    /// The path, relative to the root, of the source file that the walk
    /// examines.
    static let keptFile = "kept.rs"

    /// The text that the test report shows for this argument.
    var testDescription: String {
        switch self {
        case .unlistableDirectory: "a directory that the walk cannot list"
        case .unreadableFile: "a file that the walk cannot read for the hash"
        case .unreadableEntryType: "a file whose type the walk cannot read"
        }
    }

    /// The path, relative to the root, of the entry that the walk does not
    /// examine.
    var unexaminedPath: String {
        switch self {
        case .unlistableDirectory: "blocked"
        case .unreadableFile, .unreadableEntryType: "blocked.rs"
        }
    }

    /// The path, relative to the root, of the source file at or below
    /// `unexaminedPath`.
    var blockedFile: String {
        switch self {
        case .unlistableDirectory: "blocked/inner/b.rs"
        case .unreadableFile, .unreadableEntryType: "blocked.rs"
        }
    }

    /// Writes `blockedFile` and `keptFile` under `root`.
    /// - Parameter root: The workspace root.
    /// - Throws: The error of a write.
    func writeTree(in root: URL) throws {
        try write("fn blocked() {}", to: blockedFile, in: root)
        try write("fn kept() {}", to: Self.keptFile, in: root)
    }

    /// Runs `body` while the walk cannot examine `unexaminedPath`.
    /// - Parameters:
    ///   - root: The workspace root that `writeTree(in:)` wrote.
    ///   - body: The work. It gets the entry type reader to give to the walk.
    /// - Returns: `body`'s result.
    /// - Throws: Rethrows what `body` throws, or the error of a change of the
    ///   permissions.
    func withFailure<T>(
        in root: URL,
        _ body: (_ readEntryType: @escaping Walker.EntryTypeReader) async throws -> T
    ) async throws -> T {
        let unexaminedURL = root.appendingPathComponent(unexaminedPath)
        switch self {
        case .unlistableDirectory, .unreadableFile:
            let restoredPermissions = self == .unlistableDirectory ? restoredDirectoryPermissions : restoredFilePermissions
            return try await withPermissions(noAccessPermissions, at: unexaminedURL, restoringTo: restoredPermissions) {
                try await body(Walker.entryType(at:))
            }
        case .unreadableEntryType:
            return try await body(EntryTypeReaders.failing(for: unexaminedURL.lastPathComponent))
        }
    }
}

/// Tests for `Reconciler`/`Walker`: gitignore-aware discovery (root and
/// nested), stats correctness, and the add/change/remove reconcile flows
/// against `Store`'s `indexed_files` table — port of `cleanup.rs`'s
/// `startup_cleanup` test suite.
struct ReconcilerTests {
    @Test
    func reconcileAddsNewFilesDirty() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)
            try write("struct A {}", to: "b.swift", in: root)

            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            #expect(stats.walked == 2)
            #expect(stats.added == 2)
            #expect(stats.changed == 0)
            #expect(stats.removed == 0)

            let dirty = try await store.drainTsDirty()
            #expect(Set(dirty) == ["a.rs", "b.swift"])
        }
    }

    @Test
    func reconcileSecondPassOnUnchangedTreeIsNoOp() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)

            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            #expect(stats.walked == 1)
            #expect(stats.added == 0)
            #expect(stats.changed == 0)
            #expect(stats.removed == 0)
        }
    }

    @Test
    func reconcileMarksChangedFileDirtyAndUpdatesHash() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            // Simulate a fully-indexed file so we can observe the dirty
            // flags flip from `true` back to `false`.
            try await store.markIndexed(filePath: "a.rs", layer: .treeSitter)
            try await store.markIndexed(filePath: "a.rs", layer: .lsp)
            try await store.markIndexed(filePath: "a.rs", layer: .embedding)
            #expect(try await store.drainTsDirty().isEmpty)

            try write("fn a_modified() {}", to: "a.rs", in: root)
            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            #expect(stats.changed == 1)
            #expect(stats.added == 0)
            #expect(stats.removed == 0)
            #expect(try await store.drainTsDirty() == ["a.rs"])
            #expect(try await store.drainLspDirty() == ["a.rs"])
            #expect(try await store.drainEmbeddingDirty() == ["a.rs"])

            let storedHash = try await store.read { db in
                try Data.fetchOne(db, sql: "SELECT content_hash FROM indexed_files WHERE file_path = 'a.rs'")
            }
            let expectedDigest = SHA256.hash(data: Data("fn a_modified() {}".utf8))
            #expect(storedHash == Data(expectedDigest.prefix(16)))
        }
    }

    @Test
    func reconcileDeletesRemovedFileAndCascades() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try await store.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO ts_chunks (file_path, start_byte, end_byte, start_line, end_line, text, symbol_path, kind)
                        VALUES ('a.rs', 0, 10, 1, 1, 'fn a() {}', 'a', 'function')
                        """)
            }

            try FileManager.default.removeItem(at: root.appendingPathComponent("a.rs"))
            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            #expect(stats.removed == 1)
            #expect(stats.walked == 0)

            let remainingFiles = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_files") ?? 0
            }
            #expect(remainingFiles == 0)

            let remainingChunks = try await store.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ts_chunks") ?? 0
            }
            #expect(remainingChunks == 0)
        }
    }

    @Test
    func reconcileReportsCombinedStatsAcrossAddChangeRemoveUnchanged() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn a() {}", to: "a.rs", in: root)
            try write("fn b() {}", to: "b.rs", in: root)
            try write("fn c() {}", to: "c.rs", in: root)

            let firstStats = try await Reconciler.reconcile(store: store, rootDirectory: root)
            #expect(firstStats.added == 3)

            try FileManager.default.removeItem(at: root.appendingPathComponent("b.rs"))
            try write("fn c_modified() {}", to: "c.rs", in: root)

            let secondStats = try await Reconciler.reconcile(store: store, rootDirectory: root)
            #expect(secondStats.walked == 2)
            #expect(secondStats.removed == 1)
            #expect(secondStats.changed == 1)
            #expect(secondStats.added == 0)
        }
    }

    @Test
    func reconcileHonorsRootGitignore() async throws {
        try await withTemporaryWorkspace { root in
            try write("ignored.rs\n", to: ".gitignore", in: root)
            try write("fn ignored() {}", to: "ignored.rs", in: root)
            try write("fn kept() {}", to: "kept.rs", in: root)

            let store = try Store(rootDirectory: root)
            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            #expect(stats.walked == 1)
            #expect(stats.added == 1)

            let paths = try await store.drainTsDirty()
            #expect(paths == ["kept.rs"])
        }
    }

    @Test
    func reconcileHonorsNestedGitignoreScopedToItsDirectory() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn top() {}", to: "top.rs", in: root)
            try write("*.rs\n", to: "vendor/.gitignore", in: root)
            try write("fn skipped() {}", to: "vendor/skipped.rs", in: root)
            try write("struct Keep {}", to: "vendor/keep.swift", in: root)

            let store = try Store(rootDirectory: root)
            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let paths = Set(try await store.drainTsDirty())
            #expect(paths == ["top.rs", "vendor/keep.swift"])
            #expect(stats.walked == 2)
        }
    }

    @Test
    func reconcileHonorsGitignoreNegation() async throws {
        try await withTemporaryWorkspace { root in
            try write("*.rs\n!keep.rs\n", to: ".gitignore", in: root)
            try write("fn a() {}", to: "a.rs", in: root)
            try write("fn keep() {}", to: "keep.rs", in: root)

            let store = try Store(rootDirectory: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let paths = try await store.drainTsDirty()
            #expect(paths == ["keep.rs"])
        }
    }

    @Test
    func reconcileHonorsDirectoryOnlyGitignorePattern() async throws {
        try await withTemporaryWorkspace { root in
            try write("build/\n", to: ".gitignore", in: root)
            try write("fn generated() {}", to: "build/gen.rs", in: root)
            try write("fn kept() {}", to: "kept.rs", in: root)

            let store = try Store(rootDirectory: root)
            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            #expect(stats.walked == 1)
            let paths = try await store.drainTsDirty()
            #expect(paths == ["kept.rs"])
        }
    }

    @Test
    func reconcileSkipsCodeContextDirectory() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn hidden() {}", to: ".code-context/leaked.rs", in: root)
            try write("fn visible() {}", to: "visible.rs", in: root)

            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            #expect(stats.walked == 1)
            #expect(stats.added == 1)
            let paths = try await store.drainTsDirty()
            #expect(paths == ["visible.rs"])
        }
    }

    @Test
    func reconcileDeletesTheRowOfAFileThatIsNowIgnored() async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try write("fn generated() {}", to: "generated/g.rs", in: root)
            try write("fn kept() {}", to: "kept.rs", in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            try write("generated/\n", to: ".gitignore", in: root)
            let stats = try await Reconciler.reconcile(store: store, rootDirectory: root)

            #expect(stats.removed == 1)
            let rowKeys = try await Self.rowKeys(in: store)
            #expect(rowKeys == ["kept.rs"])
        }
    }

    @Test
    func reconcileKeepsTheRowsUnderAnUnreadableDirectory() async throws {
        try await Self.expectReconcileKeepsTheRows(under: .unlistableDirectory)
    }

    @Test
    func reconcileKeepsTheRowOfAnUnreadableFile() async throws {
        try await Self.expectReconcileKeepsTheRows(under: .unreadableFile)
    }

    @Test
    func reconcileKeepsTheRowOfAFileWhoseTypeTheWalkCannotRead() async throws {
        try await Self.expectReconcileKeepsTheRows(under: .unreadableEntryType)
    }

    /// Indexes the tree of `cause`, reconciles again while the walk cannot
    /// examine the entry of `cause`, and expects that the second reconcile
    /// removes no row, counts one skipped entry, and keeps the row of each
    /// file.
    /// - Parameter cause: The cause that makes the walk leave the entry
    ///   unexamined.
    /// - Throws: The error of the setup, of a reconcile, or of the read of the
    ///   rows.
    private static func expectReconcileKeepsTheRows(under cause: UnexaminedEntryCause) async throws {
        try await withTemporaryWorkspace { root in
            let store = try Store(rootDirectory: root)
            try cause.writeTree(in: root)
            _ = try await Reconciler.reconcile(store: store, rootDirectory: root)

            let stats = try await cause.withFailure(in: root) { readEntryType in
                try await Reconciler.reconcile(store: store, rootDirectory: root, readEntryType: readEntryType)
            }

            #expect(stats.removed == 0)
            #expect(stats.skipped == 1)
            let rowKeys = try await Self.rowKeys(in: store)
            #expect(rowKeys == [cause.blockedFile, UnexaminedEntryCause.keptFile])
        }
    }

    /// Reads the key of each row of `indexed_files`, in name order.
    /// - Parameter store: The store to read.
    /// - Returns: The `file_path` of each row, sorted.
    /// - Throws: The error of the read.
    private static func rowKeys(in store: Store) async throws -> [String] {
        try await store.read { db in
            try String.fetchAll(db, sql: "SELECT file_path FROM indexed_files ORDER BY file_path")
        }
    }
}

/// Tests for `Walker` directly: extension filtering and content hashing,
/// independent of `Reconciler`'s database reconciliation.
struct WalkerTests {
    @Test
    func walkHashesFileContentAsFirst16BytesOfSHA256() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn a() {}", to: "a.rs", in: root)

            let files = try await Walker.walk(rootDirectory: root).files
            #expect(files.count == 1)
            let file = try #require(files.first)
            #expect(file.relativePath == "a.rs")
            #expect(file.contentHash.count == 16)
            #expect(file.fileSize == Int64("fn a() {}".utf8.count))

            let expectedDigest = SHA256.hash(data: Data("fn a() {}".utf8))
            #expect(file.contentHash == Data(expectedDigest.prefix(16)))
        }
    }

    @Test
    func walkOnlyIncludesKnownLanguageExtensions() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn a() {}", to: "a.rs", in: root)
            try write("not code", to: "notes.txt", in: root)

            let files = try await Walker.walk(rootDirectory: root).files
            #expect(files.map(\.relativePath) == ["a.rs"])
        }
    }

    @Test
    func walkHonorsEachKindOfIgnoreRule() async throws {
        try await withTemporaryWorkspace { root in
            try IgnoreRulesTree.write(in: root)

            let walk = try await Walker.walk(rootDirectory: root)

            #expect(Set(walk.files.map(\.relativePath)) == IgnoreRulesTree.keptFiles)
        }
    }

    @Test(arguments: UnexaminedEntryCause.allCases)
    func walkSkipsAnEntryItCannotExamineAndReturnsTheOtherFiles(_ cause: UnexaminedEntryCause) async throws {
        try await withTemporaryWorkspace { root in
            try cause.writeTree(in: root)

            let walk = try await cause.withFailure(in: root) { readEntryType in
                try await Walker.walk(rootDirectory: root, readEntryType: readEntryType)
            }

            #expect(walk.files.map(\.relativePath) == [UnexaminedEntryCause.keptFile])
            #expect(walk.unexaminedPaths == [cause.unexaminedPath])
        }
    }

    @Test
    func walkThrowsWhenTheRootCannotBeListed() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn kept() {}", to: "kept.rs", in: root)

            _ = try await withPermissions(unlistableDirectoryPermissions, at: root, restoringTo: restoredDirectoryPermissions) {
                await #expect(throws: (any Error).self) {
                    try await Walker.walk(rootDirectory: root)
                }
            }
        }
    }

    @Test
    func enumerateFilesRespectsExplicitExtensionFilter() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn a() {}", to: "a.rs", in: root)
            try write("struct A {}", to: "b.swift", in: root)

            let rustOnly = try Walker.enumerateFiles(rootDirectory: root, extensions: ["rs"])
            #expect(rustOnly.map(\.relativePath) == ["a.rs"])
        }
    }

    @Test
    func enumerateFilesMatchesExtensionsCaseInsensitively() async throws {
        try await withTemporaryWorkspace { root in
            try write("fn a() {}", to: "Sample.RS", in: root)
            try write("def a(): pass", to: "script.PY", in: root)

            let rustOnly = try Walker.enumerateFiles(rootDirectory: root, extensions: ["rs"])
            #expect(rustOnly.map(\.relativePath) == ["Sample.RS"])

            let pythonOnly = try Walker.enumerateFiles(rootDirectory: root, extensions: ["py"])
            #expect(pythonOnly.map(\.relativePath) == ["script.PY"])
        }
    }
}
