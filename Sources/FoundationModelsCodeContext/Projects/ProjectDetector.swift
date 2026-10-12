import Dispatch
import Foundation

/// The rule-based project detector: a list of `ProjectDetectionStrategy`
/// values, one for each project kind, that it runs over the directories of a
/// file tree.
///
/// The detector reads only the file tree: one gitignore-aware walk
/// (`Walker.walkEntries(rootDirectory:)`, which reads the file system and
/// nothing else). It never uses the `CodeContext` actor, the index store, the
/// embedder, or the LSP supervisor. Thus a detection never waits for index work:
/// not for an index pass, not for an embedding pass, and not for the start of a
/// language server.
///
/// The default detector, `languageModules`, holds one `MarkerFileStrategy` for
/// each module of `Languages.all`, in registry order. The rule data (the marker
/// files and the file extensions) stays in the language modules, like the
/// `languages.yml` data of GitHub Linguist stays apart from its strategy code.
struct ProjectDetector: Sendable {
    /// The strategies of the detector, one for each project kind, in the order of
    /// the detection.
    let strategies: [any ProjectDetectionStrategy]

    /// The detector of the language modules: one `MarkerFileStrategy` for each
    /// module of `Languages.all`.
    static let languageModules = ProjectDetector(modules: Languages.all)

    /// The label of the GCD queue that runs the detections of
    /// `detectProjectsOffCooperativePool(rootDirectory:)`.
    private static let detectionQueueLabel = "FoundationModelsCodeContext.ProjectDetector"

    /// The queue that runs the detections of
    /// `detectProjectsOffCooperativePool(rootDirectory:)`. It is concurrent, thus
    /// two detections do not wait for each other.
    private static let detectionQueue = DispatchQueue(
        label: detectionQueueLabel,
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// The relative path of the root of the walk.
    private static let rootRelativePath = ""

    /// Makes a detector from explicit strategies.
    ///
    /// - Parameter strategies: The strategies, in the order of the detection.
    init(strategies: [any ProjectDetectionStrategy]) {
        self.strategies = strategies
    }

    /// Makes a detector with one `MarkerFileStrategy` for each module of
    /// `modules`.
    ///
    /// A marker that two or more modules of `modules` declare is a shared marker
    /// of each such module (see `MarkerFileStrategy`).
    ///
    /// - Parameter modules: The language modules, in the order of the detection.
    init(modules: [any LanguageModule.Type]) {
        let sharedMarkers = Self.sharedMarkers(of: modules)
        self.init(strategies: modules.map { MarkerFileStrategy(module: $0, sharedMarkers: sharedMarkers) })
    }

    /// Detects every project under `rootDirectory`, honoring `.gitignore`.
    ///
    /// Each strategy runs on each non-ignored directory, the root included. A
    /// single directory can pass more than one strategy (e.g. a directory with
    /// both `Cargo.toml` and `package.json`), and each passed strategy gives its
    /// own `DetectedProject`. Results are sorted by directory path, then by
    /// language, for deterministic output.
    ///
    /// The detection runs on the thread of the caller. An async caller that must
    /// not use a thread of the Swift cooperative pool calls
    /// `detectProjectsOffCooperativePool(rootDirectory:)`.
    ///
    /// - Parameter rootDirectory: The workspace root to scan.
    /// - Returns: One `DetectedProject` for each passed strategy in each
    ///   directory.
    /// - Throws: Rethrows `Walker.walkEntries(rootDirectory:)`'s errors.
    func detectProjects(rootDirectory: URL) throws -> [DetectedProject] {
        let directories = try Self.directories(rootDirectory: rootDirectory)
        let detected = directories.flatMap { directory in
            strategies
                .filter { $0.detects(directory) }
                .map { DetectedProject(language: $0.language, directory: directory.url) }
        }
        return detected.sorted { lhs, rhs in
            let lhsPath = lhs.directory.path
            let rhsPath = rhs.directory.path
            return lhsPath == rhsPath ? lhs.language < rhs.language : lhsPath < rhsPath
        }
    }

    /// Detects every project under `rootDirectory` on a GCD queue of the
    /// detector, not on a thread of the Swift cooperative pool.
    ///
    /// The index work (the hash task group of the reconcile, the parse, the
    /// embedding) can use each thread of the cooperative pool. A detection on
    /// that pool then waits for a free thread. This method does not, because the
    /// walk runs on `detectionQueue`. The task of the caller only suspends.
    ///
    /// - Parameter rootDirectory: The workspace root to scan.
    /// - Returns: The result of `detectProjects(rootDirectory:)`.
    /// - Throws: Rethrows `detectProjects(rootDirectory:)`'s errors.
    func detectProjectsOffCooperativePool(rootDirectory: URL) async throws -> [DetectedProject] {
        try await withCheckedThrowingContinuation { continuation in
            Self.detectionQueue.async {
                continuation.resume(with: Result(catching: { try detectProjects(rootDirectory: rootDirectory) }))
            }
        }
    }

    /// Reads the file tree under `rootDirectory` one time and makes one
    /// `ProjectDirectory` for each non-ignored directory, the root included.
    ///
    /// The grouping uses the relative paths of the walk, not URLs: a
    /// standardized URL for each entry costs most of the time on a large tree.
    /// Only the directories get a URL.
    ///
    /// - Parameter rootDirectory: The workspace root to scan.
    /// - Returns: The directories of the tree, in no particular order.
    /// - Throws: Rethrows `Walker.walkEntries(rootDirectory:)`'s errors.
    private static func directories(rootDirectory: URL) throws -> [ProjectDirectory] {
        let entries = try Walker.walkEntries(rootDirectory: rootDirectory)
        let extensionsByDirectory = subtreeFileExtensions(entries: entries)
        let root = URL(fileURLWithPath: rootDirectory.standardizedFileURL.path, isDirectory: true)
        return groupEntryNames(entries: entries).map { directory, entryNames in
            ProjectDirectory(
                url: directory.isEmpty ? root : root.appendingPathComponent(directory, isDirectory: true),
                entryNames: entryNames,
                subtreeFileExtensions: extensionsByDirectory[directory, default: []]
            )
        }
    }

    /// Groups every walked entry's name under the relative path of its
    /// containing directory, seeding the root (the empty path) so its own
    /// direct children are checked even though the walk never emits an entry
    /// for the root.
    ///
    /// - Parameter entries: The flat entry list from
    ///   `Walker.walkEntries(rootDirectory:)`.
    /// - Returns: The relative path of each visited directory (the empty path
    ///   for the root) mapped to the names of its direct, non-ignored children
    ///   (files and directories alike).
    private static func groupEntryNames(entries: [Walker.Entry]) -> [String: [String]] {
        var entryNamesByDirectory: [String: [String]] = [rootRelativePath: []]
        for entry in entries {
            entryNamesByDirectory[parentPath(of: entry.relativePath), default: []].append(entry.url.lastPathComponent)
        }
        return entryNamesByDirectory
    }

    /// Collects, for each walked directory, the lowercased extensions of
    /// every non-ignored file in its subtree.
    ///
    /// Each file adds its extension to its own directory and to each
    /// ancestor up to the root. The climb stops at the first directory that
    /// already has the extension, because an earlier file with that extension
    /// already added it to each ancestor above. Thus the work is one step for
    /// each file, plus one step for each (directory, extension) pair.
    ///
    /// - Parameter entries: The flat entry list from
    ///   `Walker.walkEntries(rootDirectory:)`.
    /// - Returns: The relative path of each directory (the same keys as
    ///   `groupEntryNames(entries:)`) mapped to the extensions, without a
    ///   leading dot, of the files below it. A directory with no file below it
    ///   has no entry.
    private static func subtreeFileExtensions(entries: [Walker.Entry]) -> [String: Set<String>] {
        var extensionsByDirectory: [String: Set<String>] = [:]
        for entry in entries where !entry.isDirectory {
            let fileExtension = Languages.normalizedFileExtension(ofPath: entry.relativePath)
            guard !fileExtension.isEmpty else { continue }
            var directory = parentPath(of: entry.relativePath)
            while extensionsByDirectory[directory, default: []].insert(fileExtension).inserted, directory != rootRelativePath {
                directory = parentPath(of: directory)
            }
        }
        return extensionsByDirectory
    }

    /// The relative path of the directory that contains `relativePath`.
    ///
    /// - Parameter relativePath: A path relative to the root of the walk, with
    ///   `/` separators.
    /// - Returns: The path before the last `/`, or `rootRelativePath` for an
    ///   entry of the root.
    private static func parentPath(of relativePath: String) -> String {
        guard let separator = relativePath.lastIndex(of: "/") else {
            return rootRelativePath
        }
        return String(relativePath[..<separator])
    }

    /// The project markers that more than one module of `modules` declares:
    /// each marker that two or more modules list in their `projectMarkers`.
    ///
    /// - Parameter modules: The language modules of the detector.
    /// - Returns: The shared markers.
    private static func sharedMarkers(of modules: [any LanguageModule.Type]) -> Set<ProjectMarker> {
        var moduleCountByMarker: [ProjectMarker: Int] = [:]
        for module in modules {
            for marker in Set(module.projectMarkers) {
                moduleCountByMarker[marker, default: 0] += 1
            }
        }
        return Set(moduleCountByMarker.filter { $0.value > 1 }.keys)
    }
}
