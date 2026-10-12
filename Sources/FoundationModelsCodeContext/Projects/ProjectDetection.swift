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
/// plan.md "Language modules (strategy pattern)". The rules run in the
/// `ProjectDetector` component, which holds one `MarkerFileStrategy` for each
/// module and reads only the file tree. Traversal is delegated entirely to
/// `Walker.walkEntries(rootDirectory:)`, so gitignore semantics (root and
/// nested `.gitignore`, hidden-entry and symlink skipping) live in exactly one
/// place rather than being reimplemented here.
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
    /// A marker that more than one module declares gives a project only when
    /// a source file of the module is below the directory of the marker. See
    /// `MarkerFileStrategy` for the rule and its reason.
    ///
    /// The detection reads only the file tree. It does not use the index or
    /// any actor, thus it never waits for index work.
    ///
    /// - Parameter rootDirectory: The workspace root to scan.
    /// - Returns: One `DetectedProject` per matched marker across every
    ///   non-ignored directory beneath `rootDirectory`, including the root
    ///   itself.
    /// - Throws: Rethrows `Walker.walkEntries(rootDirectory:)`'s errors.
    public static func detectProjects(rootDirectory: URL) throws -> [DetectedProject] {
        try ProjectDetector.languageModules.detectProjects(rootDirectory: rootDirectory)
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
}
