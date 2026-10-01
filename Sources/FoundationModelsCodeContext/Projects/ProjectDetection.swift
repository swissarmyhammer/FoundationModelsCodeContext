import Foundation

/// One language detected in a directory of a workspace, matched via a
/// `LanguageModule`'s `projectMarkers`.
///
/// Port of `swissarmyhammer-project-detection`'s `DetectedProject`, scoped to
/// the fields this task needs: the detected language and its directory. A
/// monorepo directory that matches more than one module's markers (e.g.
/// `Cargo.toml` and `package.json` in the same directory) yields one
/// `DetectedProject` per matched language, not a single multi-language
/// value.
public struct DetectedProject: Codable, Sendable, Equatable {
    /// The detected language's canonical name (`LanguageModule.name`), e.g.
    /// `"rust"`.
    public let language: String

    /// The directory containing the matched project marker.
    public let directory: URL

    /// Creates a detected project.
    ///
    /// - Parameters:
    ///   - language: The detected language's canonical name.
    ///   - directory: The directory containing the matched project marker.
    public init(language: String, directory: URL) {
        self.language = language
        self.directory = directory
    }
}

/// Detects `LanguageModule` projects under a workspace root by matching each
/// module's `projectMarkers` against directory entries.
///
/// Port of `swissarmyhammer-project-detection`'s `detect_projects`, driven by
/// `Languages.all` instead of a hardcoded `PROJECT_TYPE_SPECS` table — see
/// plan.md "Language modules (strategy pattern)". Traversal is delegated
/// entirely to `Walker.walkEntries(rootDirectory:)`, so gitignore semantics
/// (root and nested `.gitignore`, hidden-entry and symlink skipping) live in
/// exactly one place rather than being reimplemented here.
public enum ProjectDetection {
    /// Detects every project under `rootDirectory`, honoring `.gitignore`
    /// via the shared `Walker`.
    ///
    /// A directory matches a module's marker when an exact `.fileName`
    /// entry is present, or any entry's name matches a `.glob` pattern. A
    /// single directory can match multiple modules (e.g. a directory with
    /// both `Cargo.toml` and `package.json`), and each match produces its
    /// own `DetectedProject`. Results are sorted by directory path, then by
    /// language, for deterministic output.
    ///
    /// A marker that more than one module declares (see
    /// `SharedProjectMarkers`: `Makefile` and `CMakeLists.txt` for C and C++,
    /// `package.json` for TypeScript, TSX and JavaScript) does not identify
    /// one language. A `Makefile` can build only docs, and a `package.json`
    /// can hold only the scripts of a Python repository. Such a marker gives
    /// a project only when the directory of the marker, or a directory below
    /// it, holds at least one non-ignored file with an extension of the
    /// module (`LanguageModule.fileExtensions`). Each detected project starts
    /// a language server, thus without this rule a mostly-Python tree starts
    /// clangd and typescript-language-server with no file to index. A marker
    /// that only one module declares (for example `Cargo.toml`) identifies
    /// its language, and it gives a project with no further check.
    ///
    /// - Parameter rootDirectory: The workspace root to scan.
    /// - Returns: One `DetectedProject` per matched marker across every
    ///   non-ignored directory beneath `rootDirectory`, including the root
    ///   itself.
    /// - Throws: Rethrows `Walker.walkEntries(rootDirectory:)`'s errors.
    public static func detectProjects(rootDirectory: URL) throws -> [DetectedProject] {
        let entries = try Walker.walkEntries(rootDirectory: rootDirectory)
        let entryNamesByDirectory = groupEntryNames(entries: entries, rootDirectory: rootDirectory)
        let extensionsByDirectory = subtreeFileExtensions(entries: entries, rootDirectory: rootDirectory)

        var detected: [DetectedProject] = []
        for (directory, entryNames) in entryNamesByDirectory {
            let subtreeExtensions = extensionsByDirectory[directory, default: []]
            for module in Languages.all {
                let matched = matchedMarkers(of: module.projectMarkers, entryNames: entryNames)
                let identifiesModule = matched.contains { !sharedMarkers.contains($0) }
                let hasSourceFile = !subtreeExtensions.isDisjoint(with: module.fileExtensions)
                guard !matched.isEmpty, identifiesModule || hasSourceFile else { continue }
                detected.append(DetectedProject(language: module.name, directory: directory))
            }
        }

        return detected.sorted { lhs, rhs in
            let lhsPath = lhs.directory.path
            let rhsPath = rhs.directory.path
            return lhsPath == rhsPath ? lhs.language < rhs.language : lhsPath < rhsPath
        }
    }

    /// Collects the language server specs for a set of detected projects,
    /// deduped by `command` so a multi-language server (e.g.
    /// `typescript-language-server` serving both TypeScript and JavaScript)
    /// appears once even when several detected projects share it.
    ///
    /// - Parameter detectedProjects: The projects to collect server specs
    ///   for.
    /// - Returns: One `ServerSpec` per distinct `command` among the modules
    ///   matching `detectedProjects`' languages, in `Languages.all`'s
    ///   registry order.
    public static func serverSpecs(for detectedProjects: [DetectedProject]) -> [ServerSpec] {
        let detectedLanguages = Set(detectedProjects.map(\.language))
        var seenCommands: Set<String> = []
        var specs: [ServerSpec] = []
        for module in Languages.all where detectedLanguages.contains(module.name) {
            guard let spec = module.languageServer, seenCommands.insert(spec.command).inserted else {
                continue
            }
            specs.append(spec)
        }
        return specs
    }

    /// Groups every walked entry's name under its containing directory,
    /// seeding `rootDirectory` itself so its own direct children are
    /// checked even though the walk never emits an entry for the root.
    ///
    /// - Parameters:
    ///   - entries: The flat entry list from `Walker.walkEntries(rootDirectory:)`.
    ///   - rootDirectory: The workspace root the entries were walked from.
    /// - Returns: Each visited directory's standardized URL mapped to the
    ///   names of its direct, non-ignored children (files and directories
    ///   alike).
    private static func groupEntryNames(
        entries: [Walker.Entry],
        rootDirectory: URL
    ) -> [URL: [String]] {
        var entryNamesByDirectory: [URL: [String]] = [rootDirectory.standardizedFileURL: []]
        for entry in entries {
            let parentDirectory = entry.url.deletingLastPathComponent().standardizedFileURL
            entryNamesByDirectory[parentDirectory, default: []].append(entry.url.lastPathComponent)
        }
        return entryNamesByDirectory
    }

    /// Collects, for each walked directory, the lowercased extensions of
    /// every non-ignored file in its subtree.
    ///
    /// Each file adds its extension to its own directory and to each
    /// ancestor up to `rootDirectory`. The climb stops at the first
    /// directory that already has the extension, because an earlier file
    /// with that extension already added it to each ancestor above. Thus
    /// the work is one step for each file, plus one step for each
    /// (directory, extension) pair.
    ///
    /// - Parameters:
    ///   - entries: The flat entry list from `Walker.walkEntries(rootDirectory:)`.
    ///   - rootDirectory: The workspace root the entries were walked from.
    /// - Returns: Each directory's standardized URL (the same keys as
    ///   `groupEntryNames(entries:rootDirectory:)`) mapped to the extensions,
    ///   without a leading dot, of the files below it. A directory with no
    ///   file below it has no entry.
    private static func subtreeFileExtensions(
        entries: [Walker.Entry],
        rootDirectory: URL
    ) -> [URL: Set<String>] {
        let root = rootDirectory.standardizedFileURL
        var extensionsByDirectory: [URL: Set<String>] = [:]
        for entry in entries where !entry.isDirectory {
            let fileExtension = entry.url.pathExtension.lowercased()
            guard !fileExtension.isEmpty else { continue }
            var directory = entry.url.deletingLastPathComponent().standardizedFileURL
            while extensionsByDirectory[directory, default: []].insert(fileExtension).inserted, directory != root {
                let parent = directory.deletingLastPathComponent().standardizedFileURL
                guard parent != directory else { break }
                directory = parent
            }
        }
        return extensionsByDirectory
    }

    /// The project markers that more than one module of `Languages.all`
    /// declares: each marker that two or more modules list in their
    /// `projectMarkers`. `Languages.all` is fixed, thus the set is computed
    /// one time.
    private static let sharedMarkers: Set<ProjectMarker> = {
        var moduleCountByMarker: [ProjectMarker: Int] = [:]
        for module in Languages.all {
            for marker in Set(module.projectMarkers) {
                moduleCountByMarker[marker, default: 0] += 1
            }
        }
        return Set(moduleCountByMarker.filter { $0.value > 1 }.keys)
    }()

    /// The markers of `markers` that one of `entryNames` satisfies.
    ///
    /// - Parameters:
    ///   - markers: The candidate module's project markers.
    ///   - entryNames: The names of a directory's direct children.
    /// - Returns: Each `.fileName` marker present among `entryNames`, and
    ///   each `.glob` marker that matches one of them, in the order of
    ///   `markers`.
    private static func matchedMarkers(of markers: [ProjectMarker], entryNames: [String]) -> [ProjectMarker] {
        markers.filter { marker in
            entryNames.contains { entryName in matches(marker: marker, entryName: entryName) }
        }
    }

    /// Whether a single directory entry name satisfies one project marker.
    ///
    /// - Parameters:
    ///   - marker: The marker to test against.
    ///   - entryName: One directory entry's name.
    /// - Returns: `true` for a `.fileName` marker when `entryName` matches
    ///   exactly, or for a `.glob` marker when `entryName` matches its
    ///   pattern (currently only leading-`*` suffix globs are used, e.g.
    ///   `*.xcodeproj`, mirroring `find_wildcard_match` in the Rust crate).
    private static func matches(marker: ProjectMarker, entryName: String) -> Bool {
        switch marker {
        case .fileName(let name):
            return entryName == name
        case .glob(let pattern):
            guard pattern.hasPrefix("*") else {
                return entryName == pattern
            }
            return entryName.hasSuffix(pattern.dropFirst())
        }
    }
}
