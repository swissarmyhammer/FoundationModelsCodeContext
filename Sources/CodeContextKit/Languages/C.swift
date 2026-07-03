import SwiftTreeSitter
import TreeSitterC

/// The C `LanguageModule`: grammar, chunk rules, project markers, and LSP server spec for `.c` files.
///
/// - Chunk kinds are the C-applicable subset of the Rust
///   `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`
///   constant's combined "C/C++" section: `function_definition` maps to
///   `.function`; `struct_specifier` and `enum_specifier` map to `.type`.
///   `class_specifier` and `namespace_definition` are omitted — neither node
///   kind exists in `tree-sitter-c`'s grammar (classes and namespaces are
///   C++ only); see `CPPLanguage` for those.
/// - `containerNodeKinds` is empty: none of the Rust `CONTAINER_KINDS`
///   constant's entries are C-specific, and C has no member functions, so
///   there is no enclosing container node for a chunked definition to nest
///   inside.
/// - `fileExtensions` covers `.c` and `.h`; `.h` is assigned to C rather
///   than C++ since it's the plain-C convention (`CPPLanguage` claims the
///   C++-specific `.hpp`/`.hxx` header extensions instead), even though
///   `clangd` itself treats both languages as one server (see
///   `SharedServerSpecs.clangd`).
/// - `projectMarkers` are ported from `swissarmyhammer-project-detection`'s
///   `PROJECT_TYPE_SPECS` entries for `ProjectType::CMake` and
///   `ProjectType::Makefile`, which the Rust crate does not distinguish from
///   C++.
/// - `languageServer` is `SharedServerSpecs.clangd`, shared with `CPPLanguage`.
public enum CLanguage: LanguageModule {
    /// The language identifier (`"c"`).
    public static let name = "c"

    /// File extensions this module handles, without a leading dot: `["c", "h"]`.
    public static let fileExtensions = ["c", "h"]

    /// The tree-sitter-c grammar entry point used to parse `.c` source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_c())

    /// Definition node kind → meta-type mapping.
    ///
    /// `function_definition` maps to `.function`; `struct_specifier` and
    /// `enum_specifier` map to `.type`.
    public static let chunkKinds: [String: SymbolMetaType] = [
        "function_definition": .function,
        "struct_specifier": .type,
        "enum_specifier": .type,
    ]

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// Empty: C has no member functions, so there is no container node for a
    /// chunked definition to nest inside.
    public static let containerNodeKinds: Set<String> = []

    /// Marker files that identify a C project: `CMakeLists.txt` or `Makefile`, shared with C++.
    public static let projectMarkers: [ProjectMarker] = SharedProjectMarkers.cmakeOrMakefile

    /// The shared `clangd` spec (also used by C++).
    public static let languageServer: ServerSpec? = SharedServerSpecs.clangd
}
