import Foundation
import Logging

/// The one path filter of a workspace. `Walker`, `Reconciler` (through the
/// walk) and `Watcher` use it, thus the walk and the watcher accept the same
/// paths and make the same row key for each path. The LSP index worker, the
/// live operations and the diagnostics operation use it too, through
/// `acceptsDocument(relativePath:)`, before they open a document on a
/// language server.
///
/// The filter ignores a path when one of its components is ignored:
/// - a hidden component (a name that starts with `.`),
/// - a directory in `hardSkipDirectoryNames`, also when no rule file names it,
/// - a match of the rules of the `.gitignore` and `.ignore` files of the root
///   and of each directory below it, and of the `.git/info/exclude` file.
///
/// The check examines each ancestor directory of a path as a directory, and
/// then the path itself. This gives the same result as the walk, which does not
/// go into an ignored directory. A rule that ends in `/` (for example
/// `node_modules/`) thus also ignores each file below that directory.
///
/// A path that the filter cannot examine (a path that is not below the root or
/// the canonical root) is ignored.
///
/// The filter is a value. The walk adds the rules of each directory that it
/// visits with `loadRules(inDirectory:relativeComponents:)`, thus one walk gives
/// a filter with each rule of the tree. `SharedPathFilter` keeps the filter
/// that the watcher uses, and loads it again when a rule file changes.
struct PathFilter: Sendable {
    /// The names of the directories that the filter always ignores, also when
    /// no rule file names them: build output, package caches and the data
    /// directories of git and of this package.
    static let hardSkipDirectoryNames: Set<String> = [".build", "target", "node_modules", ".git", ".code-context", ".sah"]

    /// The names of the rule files that each directory can hold. A pattern of
    /// a later file wins over a pattern of an earlier file.
    static let ruleFileNames = [".gitignore", ".ignore"]

    /// The path of the exclude file of git, relative to the root. Its patterns
    /// apply as root patterns, before the patterns of the root rule files.
    static let excludeFileComponents = [".git", "info", "exclude"]

    /// The error of a rule load: a rule file exists, but the load cannot read it.
    struct LoadError: Error, Equatable {
        /// The path of the rule file, relative to the root.
        let relativePath: String
    }

    /// The root of the workspace, with its canonical form.
    let root: WorkspaceRoot

    /// The patterns of each directory that has a rule file, by the path of the
    /// directory relative to the root. The key of the root is the empty string.
    private var patternsByDirectory: [String: [GitignorePattern]] = [:]

    /// Makes a filter with only the hidden-path and hard-skip rules. The walk
    /// adds the rules of the rule files.
    /// - Parameter rootDirectory: The workspace root.
    init(rootDirectory: URL) {
        root = WorkspaceRoot(rootDirectory)
    }

    /// Walks the tree below `rootDirectory` and gives a filter with each rule
    /// of the tree.
    ///
    /// The walk does not go into an ignored directory, thus a rule file in an
    /// ignored directory gives no rules, as in git.
    /// - Parameter rootDirectory: The workspace root.
    /// - Returns: The filter with each rule.
    /// - Throws: `LoadError` when a rule file exists but the walk cannot read
    ///   it, or the error of the listing of the root.
    static func load(rootDirectory: URL) throws -> PathFilter {
        let tree = try Walker.walkTree(rootDirectory: rootDirectory)
        if let failure = tree.ruleLoadFailures.first {
            throw failure
        }
        return tree.filter
    }

    /// Reads the rule files of one directory and adds their patterns.
    ///
    /// For the root, the patterns of `.git/info/exclude` come first. A rule file
    /// that does not exist gives no patterns.
    /// - Parameters:
    ///   - directoryURL: The URL of the directory.
    ///   - relativeComponents: The path components of the directory relative to
    ///     the root. The root has no components.
    /// - Throws: `LoadError` for the first rule file that exists but that the
    ///   function cannot read. The patterns of the other rule files of the
    ///   directory are added before the function throws.
    mutating func loadRules(inDirectory directoryURL: URL, relativeComponents: [String]) throws(LoadError) {
        var ruleFiles = Self.ruleFileNames.map { [$0] }
        if relativeComponents.isEmpty {
            ruleFiles.insert(Self.excludeFileComponents, at: 0)
        }
        var patterns: [GitignorePattern] = []
        var firstFailure: LoadError?
        for ruleFile in ruleFiles {
            do throws(LoadError) {
                patterns += try Self.readPatterns(
                    at: ruleFile.reduce(directoryURL) { $0.appendingPathComponent($1) },
                    relativePath: (relativeComponents + ruleFile).joined(separator: "/")
                )
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if !patterns.isEmpty {
            patternsByDirectory[relativeComponents.joined(separator: "/")] = patterns
        }
        if let firstFailure {
            throw firstFailure
        }
    }

    /// Gives the path of `url` relative to the root, when the filter accepts it.
    /// - Parameters:
    ///   - url: A file URL below the root or below the canonical root.
    ///   - isDirectory: Whether `url` is a directory.
    /// - Returns: The relative path, or `nil` when the filter ignores `url` or
    ///   cannot examine it.
    func acceptedRelativePath(of url: URL, isDirectory: Bool) -> String? {
        guard let relativeComponents = root.relativeComponents(of: url),
            !isIgnored(relativeComponents: relativeComponents, isDirectory: isDirectory)
        else {
            return nil
        }
        return relativeComponents.joined(separator: "/")
    }

    /// Whether the filter ignores `url`.
    /// - Parameters:
    ///   - url: A file URL.
    ///   - isDirectory: Whether `url` is a directory.
    /// - Returns: `true` when the filter ignores `url`, or when `url` is not
    ///   below the root or the canonical root.
    func isIgnored(_ url: URL, isDirectory: Bool) -> Bool {
        acceptedRelativePath(of: url, isDirectory: isDirectory) == nil
    }

    /// Whether a language server may open the document at `relativePath`.
    ///
    /// The LSP index worker, the live operations and the diagnostics operation
    /// call this check before `textDocument/didOpen`. The check accepts the
    /// path only when all of these conditions are true:
    /// - `RelativePath.isSafeRelativePath(_:)` accepts the path.
    /// - The filter does not ignore the path or one of its ancestor directories.
    /// - The real path of the document from `realpath(3)` is below the
    ///   canonical root. Thus a symbolic link that points out of the root, or a
    ///   path through such a link, is not accepted.
    ///
    /// A document that does not exist has no real path, thus it is not
    /// accepted.
    /// - Parameter relativePath: The path of the document relative to the root.
    /// - Returns: `true` when a language server may open the document.
    func acceptsDocument(relativePath: String) -> Bool {
        guard RelativePath.isSafeRelativePath(relativePath) else {
            return false
        }
        let relativeComponents = relativePath.split(separator: "/").map(String.init)
        guard !isIgnored(relativeComponents: relativeComponents, isDirectory: false) else {
            return false
        }
        let documentURL = relativeComponents.reduce(root.url) { $0.appendingPathComponent($1) }
        guard let realDocumentURL = WorkspaceRoot.realURL(of: documentURL) else {
            return false
        }
        return RelativePath.components(RelativePath.components(of: realDocumentURL), after: root.canonicalComponents) != nil
    }

    /// Whether the filter ignores the path with `relativeComponents`: it
    /// examines each ancestor directory as a directory, and then the path.
    /// - Parameters:
    ///   - relativeComponents: The path components relative to the root.
    ///   - isDirectory: Whether the path is a directory.
    /// - Returns: `true` when the filter ignores the path or one of its
    ///   ancestor directories. An empty path is ignored.
    func isIgnored(relativeComponents: [String], isDirectory: Bool) -> Bool {
        guard !relativeComponents.isEmpty else {
            return true
        }
        let lastIndex = relativeComponents.count - 1
        return relativeComponents.indices.contains { index in
            isEntryIgnored(
                relativeComponents: Array(relativeComponents[...index]),
                isDirectory: index == lastIndex ? isDirectory : true
            )
        }
    }

    /// Whether the filter ignores the entry with `relativeComponents`, when the
    /// filter accepts each ancestor directory of the entry.
    ///
    /// The walk calls this form for each entry: it does not go into an ignored
    /// directory, thus the ancestors of each entry that it examines are accepted.
    /// - Parameters:
    ///   - relativeComponents: The path components of the entry relative to the
    ///     root.
    ///   - isDirectory: Whether the entry is a directory.
    /// - Returns: `true` when the entry is hidden, is a hard-skip directory, or
    ///   matches the rules. An empty path is ignored.
    func isEntryIgnored(relativeComponents: [String], isDirectory: Bool) -> Bool {
        guard let name = relativeComponents.last else {
            return true
        }
        if Self.isHidden(name) || (isDirectory && Self.hardSkipDirectoryNames.contains(name)) {
            return true
        }
        return matchesRules(relativeComponents: relativeComponents, isDirectory: isDirectory)
    }

    /// Whether a change to `url` can change the rules: `url` is the
    /// `.git/info/exclude` file, or a rule file in a directory that the filter
    /// accepts (the walk reads only the rule files of those directories).
    ///
    /// The watcher calls this BEFORE it filters an event: `.git` is hidden and a
    /// hard skip, thus the filter ignores the event of `.git/info/exclude`.
    /// - Parameter url: The URL of a changed file.
    /// - Returns: `true` when the watcher must load the rules again.
    func isRuleFileChange(_ url: URL) -> Bool {
        guard let relativeComponents = root.relativeComponents(of: url) else {
            return false
        }
        if relativeComponents == Self.excludeFileComponents {
            return true
        }
        guard let name = relativeComponents.last, Self.ruleFileNames.contains(name) else {
            return false
        }
        let directoryComponents = Array(relativeComponents.dropLast())
        return directoryComponents.isEmpty || !isIgnored(relativeComponents: directoryComponents, isDirectory: true)
    }

    /// Whether `name` is a hidden name: it starts with `.`.
    /// - Parameter name: One path component.
    /// - Returns: `true` for a hidden name.
    static func isHidden(_ name: String) -> Bool {
        name.hasPrefix(".")
    }

    /// Whether the rules ignore the entry, as git decides it: the patterns of
    /// each ancestor directory apply from the root down, and the last pattern
    /// that matches wins.
    /// - Parameters:
    ///   - relativeComponents: The path components of the entry relative to the
    ///     root. The array is not empty.
    ///   - isDirectory: Whether the entry is a directory.
    /// - Returns: `true` when the last matching pattern is not negated.
    private func matchesRules(relativeComponents: [String], isDirectory: Bool) -> Bool {
        guard !patternsByDirectory.isEmpty else {
            return false
        }
        var isMatched = false
        var directoryKey = ""
        for depth in relativeComponents.indices {
            if depth > 0 {
                directoryKey = depth == 1 ? relativeComponents[0] : directoryKey + "/" + relativeComponents[depth - 1]
            }
            guard let patterns = patternsByDirectory[directoryKey] else {
                continue
            }
            let candidate = relativeComponents[depth...].joined(separator: "/")
            for pattern in patterns where pattern.matches(relativePath: candidate, isDirectory: isDirectory) {
                isMatched = !pattern.isNegated
            }
        }
        return isMatched
    }

    /// Reads the patterns of one rule file.
    /// - Parameters:
    ///   - url: The URL of the rule file.
    ///   - relativePath: The path of the rule file relative to the root, for
    ///     the error.
    /// - Returns: The patterns, or no patterns when the file does not exist or
    ///   is a directory.
    /// - Throws: `LoadError` when the file exists but cannot be read as UTF-8
    ///   text.
    private static func readPatterns(at url: URL, relativePath: String) throws(LoadError) -> [GitignorePattern] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return []
        }
        do {
            return GitignorePattern.patterns(in: try String(contentsOf: url, encoding: .utf8))
        } catch {
            throw LoadError(relativePath: relativePath)
        }
    }
}

/// The one path filter instance of a workspace, which the rules of the rule
/// files can change while the workspace runs.
///
/// `CodeContext` makes one instance and gives it to the watcher, the LSP index
/// worker, the live operations and the diagnostics operation. They all use the
/// same instance, thus no one of them opens a path that the current rules
/// ignore.
///
/// `reload()` loads the rules off this actor, on a detached task, because the
/// load walks the tree. While a load runs, `filter` waits for it, thus a reader
/// never gets the rules from before a change that it must see.
///
/// When the load fails, the filter has only the hidden-path and hard-skip
/// rules, never no rules: with no rules, the events of `.build/`, `target/` and
/// `node_modules/` would go through.
actor SharedPathFilter {
    /// The root of the workspace.
    private let rootDirectory: URL

    /// The root of the workspace, with its canonical form. It is the root of
    /// each filter of this instance, thus the init computes the canonical
    /// form one time. A caller that makes the relative path of a URI from a
    /// language server uses it (see `WorkspaceRoot.relativePath(ofURI:)`).
    nonisolated let root: WorkspaceRoot

    /// The filter of the last complete load. Before the first load, it has only
    /// the hidden-path and hard-skip rules.
    private var current: PathFilter

    /// The load that runs, or `nil`.
    private var pendingLoad: Task<PathFilter, Never>?

    /// Makes the instance with only the hidden-path and hard-skip rules.
    /// `reload()` loads the rules of the rule files.
    /// - Parameter rootDirectory: The workspace root.
    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        let initialFilter = PathFilter(rootDirectory: rootDirectory)
        root = initialFilter.root
        current = initialFilter
    }

    /// The current filter. A read while a load runs waits for that load.
    var filter: PathFilter {
        get async {
            guard let pendingLoad else {
                return current
            }
            return await pendingLoad.value
        }
    }

    /// Whether a language server may open the document at `relativePath`,
    /// with the current filter. See `PathFilter.acceptsDocument(relativePath:)`.
    ///
    /// The check reads `realpath(3)`, thus it runs off this actor.
    /// - Parameter relativePath: The path of the document relative to the root.
    /// - Returns: `true` when a language server may open the document.
    nonisolated func acceptsDocument(relativePath: String) async -> Bool {
        await filter.acceptsDocument(relativePath: relativePath)
    }

    /// Loads the rules again, off this actor.
    ///
    /// A load that starts while another load runs waits for that load first,
    /// thus the last load wins.
    func reload() async {
        let previousLoad = pendingLoad
        let directory = rootDirectory
        let load = Task.detached(priority: .utility) {
            _ = await previousLoad?.value
            return Self.loadOrFallback(rootDirectory: directory)
        }
        pendingLoad = load
        let loaded = await load.value
        guard pendingLoad == load else {
            return
        }
        current = loaded
        pendingLoad = nil
    }

    /// Loads the rules, or gives the filter with only the hidden-path and
    /// hard-skip rules when the load fails, and logs a warning.
    /// - Parameter rootDirectory: The workspace root.
    /// - Returns: The loaded filter, or the fallback filter.
    private nonisolated static func loadOrFallback(rootDirectory: URL) -> PathFilter {
        do {
            return try PathFilter.load(rootDirectory: rootDirectory)
        } catch {
            var metadata = Log.errorDetail(of: error)
            if let loadError = error as? PathFilter.LoadError {
                metadata[CodeContextTracing.MetadataKey.filePath] = .string(loadError.relativePath)
            }
            Log.watcher.warning(
                "the watcher cannot load the ignore rules and uses only the hidden-path and hard-skip rules",
                metadata: metadata
            )
            return PathFilter(rootDirectory: rootDirectory)
        }
    }
}
