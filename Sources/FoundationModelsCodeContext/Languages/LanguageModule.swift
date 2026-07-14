import SwiftTreeSitter

/// A language's strategy: grammar, chunk rules, project markers, and LSP
/// server spec, all in one place.
///
/// This replaces the Rust side's three parallel tables (tree-sitter
/// `LANGUAGES`, the YAML `ServerSpec` registry, and the project-detection
/// marker table) with a single strategy per language — see plan.md
/// "Language modules (strategy pattern)". The chunker, project detection,
/// the LSP supervisor, and extension→language routing are all generic
/// consumers of `Languages.all`; none of them contain per-language
/// knowledge. Adding a language means one new conforming type plus one line
/// in `Languages.all` — no other file changes.
public protocol LanguageModule: Sendable {
    /// The language's canonical lowercase name, e.g. `"swift"`.
    static var name: String { get }

    /// File extensions this module handles, without a leading dot, e.g.
    /// `["swift"]`.
    static var fileExtensions: [String] { get }

    /// The tree-sitter grammar entry point, or `nil` for a detection-only
    /// module with no parser (used by `SQLLanguage`, whose upstream grammar
    /// has no working SwiftPM package — see `Languages.swift`'s grammar
    /// availability table and `SQLLanguage`'s doc comment).
    static var treeSitterLanguage: Language? { get }

    /// Definition node kind → meta-type, e.g. `"function_item": .function`,
    /// `"class_declaration": .type`. Drives semantic chunking and
    /// kind-aware ops (`findDuplicates`) without re-parsing.
    static var chunkKinds: [String: SymbolMetaType] { get }

    /// Node kinds that provide naming context for qualifying nested
    /// symbols' `symbol_path` (e.g. an `impl` block, a class, a module) but
    /// aren't themselves chunked.
    static var containerNodeKinds: Set<String> { get }

    /// Marker files (or globs) that identify a project of this language,
    /// used by project detection to decide which servers to spawn.
    static var projectMarkers: [ProjectMarker] { get }

    /// This language's LSP server spec, or `nil` for a tree-sitter-only
    /// module with no language server (used by the sql, json, yaml,
    /// markdown, and bash format modules — none of them has an entry in
    /// `builtin/lsp/*.yaml`).
    static var languageServer: ServerSpec? { get }
}
