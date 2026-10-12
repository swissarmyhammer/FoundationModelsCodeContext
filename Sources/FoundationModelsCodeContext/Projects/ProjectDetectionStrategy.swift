import Foundation

/// One directory of a workspace, as a project detection strategy sees it.
///
/// The detector makes one value for each non-ignored directory of the tree,
/// the root included. A strategy reads only this value. It does not read the
/// file system, the index, or any actor.
struct ProjectDirectory: Sendable {
    /// The standardized URL of the directory.
    let url: URL

    /// The names of the direct, non-ignored children of the directory: files and
    /// directories alike.
    let entryNames: [String]

    /// The lowercased extensions, without a leading dot, of each non-ignored file
    /// in the subtree of the directory.
    let subtreeFileExtensions: Set<String>
}

/// A rule that decides if one directory is a project of one kind.
///
/// The project detector holds one strategy for each project kind, and it runs
/// each strategy on each directory of the tree. A strategy is a pure predicate
/// over a `ProjectDirectory`, thus it cannot wait for any index work.
///
/// The shape follows the detect step of the build-pack systems (Cloud Native
/// Buildpacks `bin/detect`, Nixpacks `Provider::detect`): one independent
/// pass-or-fail rule for each kind, in a fixed order.
protocol ProjectDetectionStrategy: Sendable {
    /// The canonical name of the language of the project kind, for example
    /// `"rust"`. A passed rule gives a `DetectedProject` with this language.
    var language: String { get }

    /// Whether `directory` is a project of this kind.
    ///
    /// - Parameter directory: The directory to examine.
    /// - Returns: `true` when the rule passes for `directory`.
    func detects(_ directory: ProjectDirectory) -> Bool
}

/// The project detection strategy of one `LanguageModule`: a rule over the
/// marker files of the module.
///
/// The rule passes when an entry of the directory satisfies a marker of the
/// module (`LanguageModule.projectMarkers`). A marker that more than one module
/// declares (see `SharedProjectMarkers`: `Makefile` and `CMakeLists.txt` for C
/// and C++, `package.json` for TypeScript, TSX and JavaScript) does not
/// identify one language. A `Makefile` can build only docs, and a
/// `package.json` can hold only the scripts of a Python repository. Thus such a
/// marker passes only when the subtree of the directory holds at least one file
/// with an extension of the module (`LanguageModule.fileExtensions`). Each
/// detected project starts a language server, thus without this rule a
/// mostly-Python tree starts clangd and typescript-language-server with no file
/// to index. A marker that only one module declares (for example `Cargo.toml`)
/// identifies its language, and it passes with no further check.
struct MarkerFileStrategy: ProjectDetectionStrategy {
    /// The canonical name of the language of the module.
    let language: String

    /// The project markers of the module.
    let markers: [ProjectMarker]

    /// The markers of the module that another module also declares. Such a
    /// marker passes only with a source file of the module below the directory.
    let sharedMarkers: Set<ProjectMarker>

    /// The lowercased file extensions of the module, without a leading dot.
    let fileExtensions: Set<String>

    /// Makes the strategy of `module`.
    ///
    /// - Parameters:
    ///   - module: The language module whose markers and extensions the rule
    ///     uses.
    ///   - sharedMarkers: The markers that more than one module of the detector
    ///     declares.
    init(module: any LanguageModule.Type, sharedMarkers: Set<ProjectMarker>) {
        language = module.name
        markers = module.projectMarkers
        self.sharedMarkers = sharedMarkers.intersection(module.projectMarkers)
        fileExtensions = Set(module.fileExtensions.map { $0.lowercased() })
    }

    /// Whether `directory` holds a marker of the module that identifies the
    /// module, or a shared marker and a source file of the module below it.
    ///
    /// - Parameter directory: The directory to examine.
    /// - Returns: `true` when the rule passes for `directory`.
    func detects(_ directory: ProjectDirectory) -> Bool {
        let matched = markers.filter { marker in
            directory.entryNames.contains { entryName in Self.matches(marker: marker, entryName: entryName) }
        }
        guard !matched.isEmpty else {
            return false
        }
        let identifiesModule = matched.contains { !sharedMarkers.contains($0) }
        return identifiesModule || !directory.subtreeFileExtensions.isDisjoint(with: fileExtensions)
    }

    /// Whether a single directory entry name satisfies one project marker.
    ///
    /// - Parameters:
    ///   - marker: The marker to test against.
    ///   - entryName: One directory entry's name.
    /// - Returns: `true` for a `.fileName` marker when `entryName` matches
    ///   exactly, or for a `.glob` marker when `entryName` matches its pattern
    ///   (currently only leading-`*` suffix globs are used, e.g. `*.xcodeproj`,
    ///   mirroring `find_wildcard_match` in the Rust crate).
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
