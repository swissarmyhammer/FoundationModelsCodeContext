import SwiftTreeSitter
import TreeSitterCPP

/// The C++ `LanguageModule`: grammar, chunk rules, project markers, and LSP server spec for `.cpp` files.
///
/// - Chunk kinds are the C++-applicable subset of the Rust
///   `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`
///   constant's combined "C/C++" section: `function_definition` maps to
///   `.function`; `struct_specifier`, `class_specifier`, and `enum_specifier`
///   map to `.type`; `namespace_definition` maps to `.other` — it declares a
///   scope, not a type, the same reasoning `RustLanguage` uses for
///   `mod_item`.
/// - `containerNodeKinds` extends past the Rust `CONTAINER_KINDS` constant's
///   single C++-applicable entry (`namespace_definition`) to also cover
///   `class_specifier` and `struct_specifier`, since member functions are
///   declared nested inside class/struct bodies — a deliberate, documented
///   deviation in service of `containerNodeKinds`'s stated purpose
///   (qualifying nested symbols' `symbol_path`), the same deviation
///   `SwiftLanguage` already makes for its own container set.
/// - `fileExtensions` covers the C++-specific extensions (`.cpp`, `.cc`,
///   `.cxx`, `.hpp`, `.hxx`); plain `.h` is assigned to `CLanguage` instead.
/// - `projectMarkers` are ported from `swissarmyhammer-project-detection`'s
///   `PROJECT_TYPE_SPECS` entries for `ProjectType::CMake` and
///   `ProjectType::Makefile`, which the Rust crate does not distinguish from
///   C.
/// - `languageServer` is `SharedServerSpecs.clangd`, shared with `CLanguage`.
public enum CPPLanguage: LanguageModule {
    /// The language identifier (`"cpp"`).
    public static let name = "cpp"

    /// File extensions this module handles, without a leading dot:
    /// `["cpp", "cc", "cxx", "hpp", "hxx"]`.
    public static let fileExtensions = ["cpp", "cc", "cxx", "hpp", "hxx"]

    /// The tree-sitter-cpp grammar entry point used to parse `.cpp` source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_cpp())

    /// Definition node kind → meta-type mapping.
    ///
    /// `function_definition` maps to `.function`; `struct_specifier`,
    /// `class_specifier`, and `enum_specifier` map to `.type`;
    /// `namespace_definition` maps to `.other` since it declares a scope,
    /// not a type.
    public static let chunkKinds: [String: SymbolMetaType] = [
        "function_definition": .function,
        "struct_specifier": .type,
        "class_specifier": .type,
        "enum_specifier": .type,
        "namespace_definition": .other,
    ]

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// `namespace_definition`, `class_specifier`, and `struct_specifier`
    /// provide this naming context without being chunked themselves, so a
    /// method inside a class is qualified as `ClassName::method`.
    public static let containerNodeKinds: Set<String> = [
        "namespace_definition",
        "class_specifier",
        "struct_specifier",
    ]

    /// Marker files that identify a C++ project: `CMakeLists.txt` or `Makefile`, shared with C.
    public static let projectMarkers: [ProjectMarker] = SharedProjectMarkers.cmakeOrMakefile

    /// The shared `clangd` spec (also used by C).
    public static let languageServer: ServerSpec? = SharedServerSpecs.clangd
}
