import Foundation
import FoundationModelsCodeContext
import FoundationModelsExtras

/// # Benchmark: one cold index pass with a real embedding model.
///
/// This program measures the time of the first index pass of `CodeContext` on one source tree,
/// with a real MLX embedding model from FoundationModelsExtras. It is a local measurement step.
/// It is not part of the automated verification of this package (`swift build` and `swift test`
/// are).
///
/// Run it with `swift run -c release IndexBenchmark [root] [model]`:
///
/// - `root`: the source tree to index. The default is the current directory.
/// - `model`: the Hugging Face name of the embedding model. The default is
///   `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`.
///
/// ## What the program does
///
/// 1. It copies `root` to a new temporary directory, without the folders in
///    `excludedFolderNames`. Thus each run starts with an empty index, and the index of `root`
///    does not change.
/// 2. It loads the model with one probe embed before the timer starts. Thus the download and the
///    load of the model are not part of the index time.
/// 3. It starts a `CodeContext` on the copy and waits for the first index pass. That pass holds
///    the tree-sitter layer and the embedding layer. The LSP layer continues in its own tasks,
///    thus it is not part of the measurement.
/// 4. It prints the wall time of the pass, the embed time, the embed calls and the texts, and the
///    file counts of `indexStatus()`.
///
/// The program turns LSP auto-install off, so that the run installs no language server.
///
/// This demo is a command-line program, and it has no logging system. Each `print` below writes
/// the result that the reader asked for, and not a debug log. Thus each one carries the
/// swiftlint directive for `no_direct_standard_out_logs` on the line immediately above it.

/// The default embedding model: the default of the `embedding` slot of FoundationModelsACPAgent.
let defaultModel: ModelRef = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"

/// The folders that the copy does not include: build output, version control, and an index.
let excludedFolderNames: Set<String> = [".build", ".git", ".code-context", ".swiftpm"]

/// The text of the probe embed that loads the model before the timer starts.
let warmUpText = "load the model"

let arguments = CommandLine.arguments
let rootPath = arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath
let sourceRoot = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
let model = arguments.count > 2 ? ModelRef(stringLiteral: arguments[2]) : defaultModel

// MARK: - Copy the source tree to an empty directory

let copyRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("IndexBenchmark-\(UUID().uuidString)", isDirectory: true)
try copyTree(from: sourceRoot, to: copyRoot, excluding: excludedFolderNames)

// swiftlint:disable:next no_direct_standard_out_logs
print("Source: \(sourceRoot.path)")
// swiftlint:disable:next no_direct_standard_out_logs
print("Copy:   \(copyRoot.path)")
// swiftlint:disable:next no_direct_standard_out_logs
print("Model:  \(model.stringValue)")

// MARK: - Load the model before the timer starts

let clock = ContinuousClock()
let pooledEmbedder = PooledEmbedder(ref: model)
let loadStart = clock.now
_ = try await pooledEmbedder.embed(texts: [warmUpText])
let loadDuration = clock.now - loadStart
// swiftlint:disable:next no_direct_standard_out_logs
print("Model load and first embed: \(format(loadDuration))")

// MARK: - Run one cold index pass

let embedder = TimedEmbedder(wrapping: pooledEmbedder)
let context = try await CodeContext(
    rootDirectory: copyRoot,
    embedder: embedder,
    autoInstall: LspAutoInstall(isEnabled: false)
)
let passStart = clock.now
try await context.start()
await context.waitForFirstIndexPass()
let passDuration = clock.now - passStart
let progress = await context.indexStatus()
await context.stop()

// MARK: - Print the result

let stats = await embedder.stats.snapshot()
let passSeconds = seconds(passDuration)
let embedSeconds = seconds(stats.embedDuration)
// swiftlint:disable:next no_direct_standard_out_logs
print("""

    Index pass:       \(format(passDuration))
    Files walked:     \(progress.filesWalked)
    Files parsed:     \(progress.filesParsed)
    Files embedded:   \(progress.filesEmbedded)
    Embed calls:      \(stats.calls)
    Texts embedded:   \(stats.texts)
    Largest call:     \(stats.largestCall) texts
    Text characters:  \(stats.characters)
    Embed time:       \(format(stats.embedDuration)) (\(percent(embedSeconds, of: passSeconds)) of the pass)
    Texts per second: \(rate(stats.texts, in: passSeconds)) (pass), \(rate(stats.texts, in: embedSeconds)) (embed only)
    """)

try FileManager.default.removeItem(at: copyRoot)

// MARK: - The timed embedder

/// The counts and the time of the embed calls of one run.
actor EmbedStats {
    /// One read of the counts.
    struct Snapshot: Sendable {
        /// The number of `embed(texts:)` calls.
        let calls: Int
        /// The number of texts in all the calls.
        let texts: Int
        /// The number of characters in all the texts.
        let characters: Int
        /// The number of texts in the largest call.
        let largestCall: Int
        /// The sum of the durations of all the calls.
        let embedDuration: Duration
    }

    /// The number of `embed(texts:)` calls.
    private var calls = 0
    /// The number of texts in all the calls.
    private var texts = 0
    /// The number of characters in all the texts.
    private var characters = 0
    /// The number of texts in the largest call.
    private var largestCall = 0
    /// The sum of the durations of all the calls.
    private var embedDuration = Duration.zero

    /// Adds one call to the counts.
    ///
    /// - Parameters:
    ///   - textCount: The number of texts in the call.
    ///   - characterCount: The number of characters in the texts of the call.
    ///   - duration: The duration of the call.
    func record(textCount: Int, characterCount: Int, duration: Duration) {
        calls += 1
        texts += textCount
        characters += characterCount
        largestCall = max(largestCall, textCount)
        embedDuration += duration
    }

    /// Gives the current counts.
    ///
    /// - Returns: The counts of all the calls until now.
    func snapshot() -> Snapshot {
        Snapshot(
            calls: calls,
            texts: texts,
            characters: characters,
            largestCall: largestCall,
            embedDuration: embedDuration
        )
    }
}

/// A `PooledEmbedding` that forwards each call to another embedder, and records the count and
/// the time of each call in `stats`.
struct TimedEmbedder: PooledEmbedding {
    /// The embedder that makes the vectors.
    let wrapped: any PooledEmbedding

    /// The counts and the time of the calls.
    let stats = EmbedStats()

    /// Makes a timed embedder over `wrapped`.
    ///
    /// - Parameter wrapped: The embedder that makes the vectors.
    init(wrapping wrapped: any PooledEmbedding) {
        self.wrapped = wrapped
    }

    /// Gives one vector for each text from `wrapped`, and records the call.
    ///
    /// - Parameter texts: The texts.
    /// - Returns: One vector for each text, in the order of `texts`.
    /// - Throws: The error of `wrapped`.
    func embed(texts: [String]) async throws -> [[Float]] {
        let clock = ContinuousClock()
        let start = clock.now
        let vectors = try await wrapped.embed(texts: texts)
        await stats.record(
            textCount: texts.count,
            characterCount: texts.reduce(0) { sum, text in sum + text.count },
            duration: clock.now - start
        )
        return vectors
    }
}

// MARK: - Helpers

/// Copies each file below `source` to the same relative path below `destination`.
///
/// The copy does not go into a folder whose name is in `excludedNames`. It does not follow
/// symbolic links.
///
/// - Parameters:
///   - source: The folder to copy.
///   - destination: The new folder. It must not exist.
///   - excludedNames: The names of the folders that the copy does not include.
/// - Throws: The error of `FileManager` when a folder or a file cannot be made.
func copyTree(from source: URL, to destination: URL, excluding excludedNames: Set<String>) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
    let entries = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: keys)
    for entry in entries {
        let values = try entry.resourceValues(forKeys: Set(keys))
        if values.isSymbolicLink == true {
            continue
        }
        let target = destination.appendingPathComponent(entry.lastPathComponent)
        if values.isDirectory == true {
            if excludedNames.contains(entry.lastPathComponent) {
                continue
            }
            try copyTree(from: entry, to: target, excluding: excludedNames)
        } else {
            try fileManager.copyItem(at: entry, to: target)
        }
    }
}

/// Gives `duration` in seconds.
///
/// - Parameter duration: The duration.
/// - Returns: The number of seconds, with the fraction.
func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

/// Gives `duration` as text in seconds, with two decimals.
///
/// - Parameter duration: The duration.
/// - Returns: For example `12.34 s`.
func format(_ duration: Duration) -> String {
    String(format: "%.2f s", seconds(duration))
}

/// Gives `count / interval` as text, with one decimal.
///
/// - Parameters:
///   - count: The number of items.
///   - interval: The time in seconds.
/// - Returns: The rate, or `n/a` when `interval` is 0.
func rate(_ count: Int, in interval: Double) -> String {
    guard interval > 0 else {
        return "n/a"
    }
    return String(format: "%.1f", Double(count) / interval)
}

/// Gives `part / whole` as a percentage text, with no decimals.
///
/// - Parameters:
///   - part: The part.
///   - whole: The whole.
/// - Returns: For example `87%`, or `n/a` when `whole` is 0.
func percent(_ part: Double, of whole: Double) -> String {
    guard whole > 0 else {
        return "n/a"
    }
    return String(format: "%.0f%%", part / whole * 100)
}
