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
    /// - Parameter rootDirectory: The workspace root to scan.
    /// - Returns: One `DetectedProject` per matched marker across every
    ///   non-ignored directory beneath `rootDirectory`, including the root
    ///   itself.
    /// - Throws: Rethrows `Walker.walkEntries(rootDirectory:)`'s errors.
    public static func detectProjects(rootDirectory: URL) throws -> [DetectedProject] {
        let entries = try Walker.walkEntries(rootDirectory: rootDirectory)
        let entryNamesByDirectory = groupEntryNames(entries: entries, rootDirectory: rootDirectory)

        var detected: [DetectedProject] = []
        for (directory, entryNames) in entryNamesByDirectory {
            for module in Languages.all where matches(markers: module.projectMarkers, entryNames: entryNames) {
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

    /// Whether any of `entryNames` satisfies one of `markers`.
    ///
    /// - Parameters:
    ///   - markers: The candidate module's project markers.
    ///   - entryNames: The names of a directory's direct children.
    /// - Returns: `true` if an exact `.fileName` marker is present among
    ///   `entryNames`, or a `.glob` marker matches one of them.
    private static func matches(markers: [ProjectMarker], entryNames: [String]) -> Bool {
        markers.contains { marker in
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
        case let .fileName(name):
            return entryName == name
        case let .glob(pattern):
            guard pattern.hasPrefix("*") else {
                return entryName == pattern
            }
            return entryName.hasSuffix(pattern.dropFirst())
        }
    }
}
