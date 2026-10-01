import Darwin
import Foundation
import GRDB
import Testing

@testable import FoundationModelsCodeContext

/// The benchmark of `GrepCode.run(store:pattern:languages:filePattern:maxResults:)` on a tree of
/// the size of a Django clone.
///
/// The tree is synthetic: 2000 Python files, each with 4 classes of 10 methods. The suite writes
/// the files to disk and writes the chunk rows of the files directly into the store, in the same
/// shape that the chunker writes: each class chunk holds the text of its method chunks. Thus the
/// store holds 88000 chunks and about 40 MB of chunk text, and the setup does not need a full
/// tree-sitter pass.
///
/// Each test records the wall time and the CPU time of one search as a test attachment, and fails
/// when a time is more than its budget. Before the fix, one search used about 46 seconds of CPU on
/// this tree (one task and one regex compile for each chunk), and a Django clone took 95 seconds
/// to more than 120 seconds while its first index pass ran.
///
/// The suite is serialized, so the two benchmarks do not use the same CPUs at the same time.
@Suite(.serialized)
struct GrepCodeScaleTests {
    /// The number of files in the synthetic tree.
    private static let fileCount = 2000

    /// The number of directories that hold the files. A real tree has many directories.
    private static let directoryCount = 40

    /// The number of classes in each file.
    private static let classesPerFile = 4

    /// The number of methods in each class.
    private static let methodsPerClass = 10

    /// The index of the one file that holds the method that the search finds.
    private static let needleFileIndex = 0

    /// The name of the method that the search finds. Only one method of the tree has this name.
    private static let needleMethodName = "add_immediate_loading"

    /// The pattern that the agent sent in the SWE-bench run where grepCode was slow.
    private static let pattern = "def add_immediate_loading|def add_deferred_loading|def clear_deferred_loading"

    /// The number of files that the tree-sitter pass indexes again while the second benchmark
    /// searches. The pass is sequential, thus it runs during all of the search.
    private static let indexPassFileCount = 500

    /// The most wall time that one search can use: "a few seconds".
    private static let wallTimeBudget: Duration = .seconds(5)

    /// The most CPU time, in seconds, that one search can use. Before the fix, one search used
    /// about 46 seconds.
    private static let cpuTimeBudgetSeconds = 5.0

    /// The number of microseconds in one second, to convert a `timeval` to seconds.
    private static let microsecondsPerSecond = 1_000_000.0

    @Test
    func grepCodeOnADjangoSizeTreeAnswersInAFewSeconds() async throws {
        try await withTemporaryWorkspace { root in
            let store = try await Self.makeIndexedTree(root: root)

            let (result, measurement) = try await Self.measureSearch(store: store)
            Self.record(measurement, named: "grep-code-idle.txt")

            #expect(result.matches.map(\.symbolPath) == [Self.needleSymbolPath])
            #expect(result.totalChunksSearched == Self.chunkCount)
            #expect(!result.isIndexPartial)
            #expect(measurement.wallTime < Self.wallTimeBudget, "wall time \(measurement.wallTime)")
            #expect(measurement.cpuSeconds < Self.cpuTimeBudgetSeconds, "CPU time \(measurement.cpuSeconds) s")
        }
    }

    @Test
    func grepCodeAnswersInAFewSecondsWhileAnIndexPassRuns() async throws {
        try await withTemporaryWorkspace { root in
            let store = try await Self.makeIndexedTree(root: root)
            try await Self.markDirty(filePaths: Self.indexPassFilePaths, store: store)
            let indexPass = Task {
                try await TreeSitterWorker.run(store: store, rootDirectory: root)
            }

            let (result, measurement) = try await Self.measureSearch(store: store)
            indexPass.cancel()
            _ = await indexPass.result
            Self.record(measurement, named: "grep-code-during-index-pass.txt")

            #expect(result.matches.map(\.symbolPath) == [Self.needleSymbolPath])
            #expect(result.isIndexPartial)
            #expect(measurement.wallTime < Self.wallTimeBudget, "wall time \(measurement.wallTime)")
            #expect(measurement.cpuSeconds < Self.cpuTimeBudgetSeconds, "CPU time \(measurement.cpuSeconds) s")
        }
    }

    // MARK: - Measurement

    /// The wall time and the CPU time of one search.
    private struct Measurement {
        /// The wall time of the search.
        let wallTime: Duration

        /// The CPU time of this process during the search, in seconds, user and system.
        let cpuSeconds: Double
    }

    /// Runs one search for `pattern` and measures it.
    /// - Parameter store: The store to search.
    /// - Returns: The result of the search and its measurement.
    /// - Throws: The errors of the search.
    private static func measureSearch(store: Store) async throws -> (GrepCodeResult, Measurement) {
        let clock = ContinuousClock()
        let cpuAtStart = processCPUSeconds()
        let start = clock.now
        let result = try await GrepCode.run(store: store, pattern: pattern)
        let measurement = Measurement(wallTime: start.duration(to: clock.now), cpuSeconds: processCPUSeconds() - cpuAtStart)
        return (result, measurement)
    }

    /// The user and system CPU time of this process, in seconds.
    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return seconds(of: usage.ru_utime) + seconds(of: usage.ru_stime)
    }

    /// Converts `time` to seconds.
    /// - Parameter time: A time from `getrusage`.
    /// - Returns: The time in seconds.
    private static func seconds(of time: timeval) -> Double {
        Double(time.tv_sec) + Double(time.tv_usec) / microsecondsPerSecond
    }

    /// Attaches `measurement` to the current test, so that the test report records the times.
    /// - Parameters:
    ///   - measurement: The times of one search.
    ///   - name: The name of the attachment.
    private static func record(_ measurement: Measurement, named name: String) {
        let text = "chunks \(chunkCount), wall time \(measurement.wallTime), CPU time \(measurement.cpuSeconds) s\n"
        Attachment.record(text, named: name)
    }

    // MARK: - The synthetic tree

    /// The number of chunks in the synthetic tree: one for each class and one for each method.
    private static var chunkCount: Int {
        fileCount * classesPerFile * (1 + methodsPerClass)
    }

    /// The symbol path of the method that the search finds.
    private static var needleSymbolPath: String {
        "\(className(fileIndex: needleFileIndex, classIndex: 0)).\(needleMethodName)"
    }

    /// The paths of the files that the tree-sitter pass of the second benchmark indexes again.
    /// The needle file is not one of them.
    private static var indexPassFilePaths: [String] {
        (needleFileIndex + 1...indexPassFileCount).map(filePath(fileIndex:))
    }

    /// Writes the synthetic tree under `root`, and fills a new store with its files and chunks.
    /// Each file is marked tree-sitter-indexed, as after a complete pass.
    /// - Parameter root: The workspace root.
    /// - Returns: The filled store.
    /// - Throws: The errors of the file writes and of the store.
    private static func makeIndexedTree(root: URL) async throws -> Store {
        let files = (0..<fileCount).map(makeFile(fileIndex:))
        for file in files {
            try write(file.text, to: file.path, in: root)
        }
        let store = try Store(rootDirectory: root)
        _ = try await Reconciler.reconcile(store: store, rootDirectory: root)
        try await store.write { db in
            try insertChunks(files.flatMap(\.chunks), db: db)
            try db.execute(sql: "UPDATE \(Schema.IndexedFiles.table) SET \(Schema.IndexedFiles.tsIndexed) = 1")
        }
        return store
    }

    /// Marks each file of `filePaths` as not tree-sitter-indexed, as after a change on disk.
    /// - Parameters:
    ///   - filePaths: The files to mark.
    ///   - store: The store that holds the files.
    /// - Throws: The errors of the store.
    private static func markDirty(filePaths: [String], store: Store) async throws {
        try await store.write { db in
            let statement = try db.makeStatement(
                sql: "UPDATE \(Schema.IndexedFiles.table) SET \(Schema.IndexedFiles.tsIndexed) = 0 WHERE \(Schema.IndexedFiles.filePath) = ?"
            )
            for filePath in filePaths {
                try statement.execute(arguments: [filePath])
            }
        }
    }

    /// Inserts `chunks` into `ts_chunks`.
    /// - Parameters:
    ///   - chunks: The chunks to insert.
    ///   - db: The database connection of a write transaction.
    /// - Throws: The errors of the database.
    private static func insertChunks(_ chunks: [SyntheticChunk], db: Database) throws {
        let statement = try db.makeStatement(
            sql: """
                INSERT INTO \(Schema.TsChunks.table)
                    (\(Schema.TsChunks.filePath), \(Schema.TsChunks.startByte), \(Schema.TsChunks.endByte), \
                     \(Schema.TsChunks.startLine), \(Schema.TsChunks.endLine), \(Schema.TsChunks.text), \
                     \(Schema.TsChunks.symbolPath), \(Schema.TsChunks.kind))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """
        )
        for chunk in chunks {
            try statement.execute(arguments: [
                chunk.filePath, chunk.startByte, chunk.endByte, chunk.startLine, chunk.endLine, chunk.text,
                chunk.symbolPath, chunk.kind.rawValue,
            ])
        }
    }

    /// The path of one file of the synthetic tree, relative to the root.
    /// - Parameter fileIndex: The index of the file.
    /// - Returns: The relative path.
    private static func filePath(fileIndex: Int) -> String {
        "pkg\(fileIndex % directoryCount)/module\(fileIndex).py"
    }

    /// The name of one class of the synthetic tree. Each class name occurs one time only.
    /// - Parameters:
    ///   - fileIndex: The index of the file that holds the class.
    ///   - classIndex: The index of the class in its file.
    /// - Returns: The class name.
    private static func className(fileIndex: Int, classIndex: Int) -> String {
        "Model\(fileIndex)x\(classIndex)"
    }

    /// The name of one method of the synthetic tree.
    /// - Parameters:
    ///   - fileIndex: The index of the file that holds the method.
    ///   - classIndex: The index of the class of the method.
    ///   - methodIndex: The index of the method in its class.
    /// - Returns: The method name.
    private static func methodName(fileIndex: Int, classIndex: Int, methodIndex: Int) -> String {
        let isNeedle = fileIndex == needleFileIndex && classIndex == 0 && methodIndex == 0
        return isNeedle ? needleMethodName : "method_\(methodIndex)"
    }

    /// Builds the text and the chunks of one file of the synthetic tree.
    /// - Parameter fileIndex: The index of the file.
    /// - Returns: The file.
    private static func makeFile(fileIndex: Int) -> SyntheticFile {
        var builder = SyntheticFileBuilder(path: filePath(fileIndex: fileIndex))
        builder.appendLine("import os")
        builder.appendLine("from django.db import models")
        builder.appendLine("")
        for classIndex in 0..<classesPerFile {
            appendClass(fileIndex: fileIndex, classIndex: classIndex, to: &builder)
        }
        return builder.file
    }

    /// Appends one class and its methods to `builder`, and records their chunks.
    /// - Parameters:
    ///   - fileIndex: The index of the file.
    ///   - classIndex: The index of the class in its file.
    ///   - builder: The builder of the file.
    private static func appendClass(fileIndex: Int, classIndex: Int, to builder: inout SyntheticFileBuilder) {
        let name = className(fileIndex: fileIndex, classIndex: classIndex)
        let classStart = builder.position
        builder.appendLine("class \(name)(models.Model):")
        builder.appendLine("    \"\"\"A model of the synthetic tree.\"\"\"")
        for methodIndex in 0..<methodsPerClass {
            builder.appendLine("")
            let methodStart = builder.position
            let method = methodName(fileIndex: fileIndex, classIndex: classIndex, methodIndex: methodIndex)
            builder.appendLine("    def \(method)(self, value, other=None):")
            builder.appendLine("        result = self.compute(value) + \(methodIndex)")
            builder.appendLine("        if other is not None:")
            builder.appendLine("            result += other.only(value).defer(value, 'name', 'size')")
            builder.appendLine("        for item in range(result):")
            builder.appendLine("            self.items.append(item * \(classIndex))")
            builder.appendLine("        return result")
            builder.addChunk(from: methodStart, symbolPath: "\(name).\(method)", kind: .method)
        }
        builder.addChunk(from: classStart, symbolPath: name, kind: .type)
        builder.appendLine("")
    }
}

/// One `ts_chunks` row of the synthetic tree.
private struct SyntheticChunk {
    /// The path of the file, relative to the root.
    let filePath: String

    /// The start offset of the chunk in its file, in UTF-8 bytes.
    let startByte: Int

    /// The end offset of the chunk in its file, in UTF-8 bytes.
    let endByte: Int

    /// The zero-based line of the start of the chunk.
    let startLine: Int

    /// The zero-based line of the end of the chunk.
    let endLine: Int

    /// The text of the chunk.
    let text: String

    /// The qualified symbol path of the chunk.
    let symbolPath: String

    /// The kind of the symbol of the chunk.
    let kind: SymbolMetaType
}

/// One file of the synthetic tree: its text and its chunks.
private struct SyntheticFile {
    /// The path of the file, relative to the root.
    let path: String

    /// The text of the file.
    let text: String

    /// The chunks of the file.
    let chunks: [SyntheticChunk]
}

/// A position in the text of a file that a `SyntheticFileBuilder` builds.
private struct SyntheticPosition {
    /// The offset in UTF-8 bytes.
    let byte: Int

    /// The zero-based line.
    let line: Int
}

/// Builds the text of one file line by line, and records chunks at the byte and line positions of
/// that text.
private struct SyntheticFileBuilder {
    /// The path of the file, relative to the root.
    let path: String

    /// The text that the builder holds.
    private var text = ""

    /// The number of complete lines in `text`.
    private var lineCount = 0

    /// The chunks that the builder recorded.
    private var chunks: [SyntheticChunk] = []

    /// Creates an empty builder.
    /// - Parameter path: The path of the file, relative to the root.
    init(path: String) {
        self.path = path
    }

    /// The position after the last complete line.
    var position: SyntheticPosition {
        SyntheticPosition(byte: text.utf8.count, line: lineCount)
    }

    /// The file that the builder holds.
    var file: SyntheticFile {
        SyntheticFile(path: path, text: text, chunks: chunks)
    }

    /// Appends one line and its line break.
    /// - Parameter line: The text of the line, with no line break.
    mutating func appendLine(_ line: String) {
        text += line + "\n"
        lineCount += 1
    }

    /// Records one chunk from `start` to the end of the last line, with no final line break, as
    /// the chunker does.
    /// - Parameters:
    ///   - start: The position of the start of the chunk.
    ///   - symbolPath: The qualified symbol path of the chunk.
    ///   - kind: The kind of the symbol of the chunk.
    mutating func addChunk(from start: SyntheticPosition, symbolPath: String, kind: SymbolMetaType) {
        let utf8 = text.utf8
        let endByte = utf8.count - 1
        let lower = utf8.index(utf8.startIndex, offsetBy: start.byte)
        let upper = utf8.index(utf8.startIndex, offsetBy: endByte)
        chunks.append(
            SyntheticChunk(
                filePath: path,
                startByte: start.byte,
                endByte: endByte,
                startLine: start.line,
                endLine: lineCount - 1,
                text: String(text[lower..<upper]),
                symbolPath: symbolPath,
                kind: kind
            )
        )
    }
}
