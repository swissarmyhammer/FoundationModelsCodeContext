import SwiftTreeSitter
import TreeSitterPython

/// The Python `LanguageModule`: grammar, chunk rules, project markers, and
/// LSP server spec for `.py` files.
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
    public static let name = "python"

    public static let fileExtensions = ["py"]

    public static let treeSitterLanguage: Language? = Language(tree_sitter_python())

    public static let chunkKinds: [String: SymbolMetaType] = [
        "function_definition": .function,
        "class_definition": .type,
        "decorated_definition": .other,
    ]

    public static let containerNodeKinds: Set<String> = [
        "class_definition",
    ]

    public static let projectMarkers: [ProjectMarker] = [
        .fileName("pyproject.toml"),
        .fileName("setup.py"),
    ]

    public static let languageServer: ServerSpec? = ServerSpec(
        command: "pylsp",
        languageIds: ["python"],
        installHint: "Install python-lsp-server: pip install python-lsp-server"
    )
}
