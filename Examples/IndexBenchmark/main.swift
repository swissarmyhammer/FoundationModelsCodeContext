import ExampleSupport
import Foundation
import FoundationModelsCodeContext
import FoundationModelsExtras

/// # Benchmark: one cold index pass with a real embedding model.
///
/// This program measures the time of the first index pass of `CodeContext` on one source tree,
/// with a real MLX embedding model from FoundationModelsExtras. It is a local measurement step.
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
/// The program turns LSP auto-install off, so that the run installs no language server. It runs no
/// `searchCode`, so it gives a selection factory that throws if a search ever asks for a model.
///
/// This demo is a command-line program, and it has no logging system. It writes each result that
/// the reader asked for through `ExampleOutput.report(_:)`, the one place that holds the swiftlint
/// directive for `no_direct_standard_out_logs`.

/// The default embedding model: the default of the `embedding` slot of FoundationModelsACPAgent.
let defaultModel: ModelRef = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"

/// The folders that the copy does not include: build output, version control, and an index.
let excludedFolderNames: Set<String> = [".build", ".git", ".code-context", ".swiftpm"]

/// The error of `unusedSelection`: this program runs no search, so no selection model is needed.
struct SelectionNotUsedError: Error {}

/// The selection factory of this program. `CodeContext` needs one, and this program runs no search.
let unusedSelection: SelectionFactory = { _ in throw SelectionNotUsedError() }

/// The text of the probe embed that loads the model before the timer starts.
let warmUpText = "load the model"

/// The number of attoseconds in one second, to turn the fraction of a `Duration` into seconds.
let attosecondsPerSecond = 1e18

/// The factor that turns a fraction into a percentage.
let percentFactor = 100.0

let sourceRoot = ExampleArguments.directoryURL()
let model = ModelRef(stringLiteral: ExampleArguments.secondArgument(default: defaultModel.stringValue))

// MARK: - Copy the source tree to an empty directory

let copyRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("IndexBenchmark-\(UUID().uuidString)", isDirectory: true)
try copyTree(from: sourceRoot, to: copyRoot, excluding: excludedFolderNames)

ExampleOutput.report("Source: \(sourceRoot.path)")
ExampleOutput.report("Copy:   \(copyRoot.path)")
ExampleOutput.report("Model:  \(model.stringValue)")

// MARK: - Load the model before the timer starts

let pooledEmbedder = PooledEmbedder(ref: model)
let (_, loadDuration) = try await timed {
    try await pooledEmbedder.embed(texts: [warmUpText])
}
ExampleOutput.report("Model load and first embed: \(loadDuration.formattedSeconds)")

// MARK: - Run one cold index pass

let embedder = TimedEmbedder(wrapping: pooledEmbedder)
let context = try await CodeContext(
    rootDirectory: copyRoot,
    embedder: embedder,
    selection: unusedSelection,
    autoInstall: LspAutoInstall(isEnabled: false)
)
let (_, passDuration) = try await timed {
    try await context.start()
    await context.waitForFirstIndexPass()
}
let progress = await context.indexStatus()
await context.stop()

// MARK: - Print the result

let stats = await embedder.stats.snapshot()
let passSeconds = passDuration.inSeconds
let embedSeconds = stats.embedDuration.inSeconds
ExampleOutput.report(
    """

    Index pass:       \(passDuration.formattedSeconds)
    Files walked:     \(progress.filesWalked)
    Files parsed:     \(progress.filesParsed)
    Files embedded:   \(progress.filesEmbedded)
    Embed calls:      \(stats.calls)
    Texts embedded:   \(stats.texts)
    Largest call:     \(stats.largestCall) texts
    Text characters:  \(stats.characters)
    Embed time:       \(stats.embedDuration.formattedSeconds) (\(percent(embedSeconds, of: passSeconds)) of the pass)
    Texts per second: \(rate(stats.texts, in: passSeconds)) (pass), \(rate(stats.texts, in: embedSeconds)) (embed only)
    """)

try FileManager.default.removeItem(at: copyRoot)

// MARK: - The timed embedder

/// The counts and the time of the embed calls of one run.
actor EmbedStats {
    /// The counts and the time of the embed calls until now.
    struct Snapshot: Sendable {
        /// The number of `embed(texts:)` calls.
        var calls = 0
        /// The number of texts in all the calls.
        var texts = 0
        /// The number of characters in all the texts.
        var characters = 0
        /// The number of texts in the largest call.
        var largestCall = 0
        /// The sum of the durations of all the calls.
        var embedDuration = Duration.zero
    }

    /// The counts and the time of the calls until now.
    private var counts = Snapshot()

    /// Adds one call to the counts.
    ///
    /// - Parameters:
    ///   - textCount: The number of texts in the call.
    ///   - characterCount: The number of characters in the texts of the call.
    ///   - duration: The duration of the call.
    func record(textCount: Int, characterCount: Int, duration: Duration) {
        counts.calls += 1
        counts.texts += textCount
        counts.characters += characterCount
        counts.largestCall = max(counts.largestCall, textCount)
        counts.embedDuration += duration
    }

    /// Gives the current counts.
    ///
    /// - Returns: The counts of all the calls until now.
    func snapshot() -> Snapshot {
        counts
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
        let (vectors, duration) = try await timed {
            try await wrapped.embed(texts: texts)
        }
        await stats.record(
            textCount: texts.count,
            characterCount: texts.reduce(0) { sum, text in sum + text.count },
            duration: duration
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

/// Runs `work` and measures its wall time.
///
/// - Parameter work: The call to measure.
/// - Returns: The value of `work`, and the time that it took.
/// - Throws: The error of `work`.
func timed<Value>(_ work: () async throws -> Value) async throws -> (value: Value, duration: Duration) {
    let clock = ContinuousClock()
    let start = clock.now
    let value = try await work()
    return (value, clock.now - start)
}

extension Duration {
    /// The duration in seconds, with the fraction.
    var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / attosecondsPerSecond
    }

    /// The duration as text in seconds, with two decimals, for example `12.34 s`.
    var formattedSeconds: String {
        String(format: "%.2f s", inSeconds)
    }
}

/// Gives `numerator / denominator` as text.
///
/// - Parameters:
///   - numerator: The dividend.
///   - denominator: The divisor.
///   - scale: The factor that multiplies the quotient, for example 100 for a percentage.
///   - pattern: The `String(format:)` pattern of the result. It takes one `Double`.
/// - Returns: The formatted quotient, or `n/a` when `denominator` is 0.
func quotient(_ numerator: Double, over denominator: Double, scale: Double = 1, pattern: String) -> String {
    guard denominator > 0 else {
        return "n/a"
    }
    return String(format: pattern, numerator / denominator * scale)
}

/// Gives `count / interval` as text, with one decimal.
///
/// - Parameters:
///   - count: The number of items.
///   - interval: The time in seconds.
/// - Returns: The rate, or `n/a` when `interval` is 0.
func rate(_ count: Int, in interval: Double) -> String {
    quotient(Double(count), over: interval, pattern: "%.1f")
}

/// Gives `part / whole` as a percentage text, with no decimals.
///
/// - Parameters:
///   - part: The part.
///   - whole: The whole.
/// - Returns: For example `87%`, or `n/a` when `whole` is 0.
func percent(_ part: Double, of whole: Double) -> String {
    quotient(part, over: whole, scale: percentFactor, pattern: "%.0f%%")
}
