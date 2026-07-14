import SwiftTreeSitter
import TreeSitterPython

/// The Python `LanguageModule`: grammar, chunk rules, project markers, and LSP server spec for `.py` files.
///
/// - Chunk kinds are ported from the Python section of the Rust
///   `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`
///   constant. `function_definition` covers both free functions and methods
///   in tree-sitter-python's grammar (no separate method node kind), so it
///   maps to `.function` rather than `.method`. `decorated_definition`
///   wraps whichever definition it decorates (function or class) and so
///   can't be classified from its own node kind alone; it maps to `.other`.
/// - `containerNodeKinds` is the Python-applicable subset of the Rust
///   `CONTAINER_KINDS` constant (`class_definition`).
/// - `projectMarkers` are ported from `swissarmyhammer-project-detection`'s
///   `PROJECT_TYPE_SPECS` entry for `ProjectType::Python` (`pyproject.toml`,
///   `setup.py` — the crate's table does not include `requirements.txt`,
///   despite plan.md's prose mentioning it).
/// - `languageServer` is ported from `builtin/lsp/pylsp.yaml`.
public enum PythonLanguage: LanguageModule {
    /// The language identifier (`"python"`).
    public static let name = "python"

    /// File extensions this module handles, without a leading dot: `["py"]`.
    public static let fileExtensions = ["py"]

    /// The tree-sitter-python grammar entry point used to parse `.py` source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_python())

    /// Definition node kind → meta-type mapping.
    ///
    /// `function_definition` maps to `.function` (covers both free functions
    /// and methods, since tree-sitter-python has no separate method node
    /// kind); `class_definition` maps to `.type`; `decorated_definition`
    /// maps to `.other` since it wraps whichever definition it decorates and
    /// can't be classified on its own.
    public static let chunkKinds: [String: SymbolMetaType] = [
        "function_definition": .function,
        "class_definition": .type,
        "decorated_definition": .other,
    ]

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// Class definitions provide this naming context without being chunked
    /// themselves, so a method inside a class is qualified as
    /// `ClassName.method`.
    public static let containerNodeKinds: Set<String> = [
        "class_definition",
    ]

    /// Marker files that identify a Python project.
    ///
    /// `pyproject.toml` or `setup.py`.
    public static let projectMarkers: [ProjectMarker] = [
        .fileName("pyproject.toml"),
        .fileName("setup.py"),
    ]

    /// The Python language server spec (`pylsp`).
    ///
    /// Typed as optional per the protocol to allow tree-sitter-only modules
    /// with no server; Python always provides one.
    public static let languageServer: ServerSpec? = ServerSpec(
        command: "pylsp",
        languageIDs: [name],
        installHint: "Install python-lsp-server: pip install python-lsp-server"
    )
}
