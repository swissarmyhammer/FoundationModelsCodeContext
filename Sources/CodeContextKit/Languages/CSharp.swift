import SwiftTreeSitter
import TreeSitterCSharp

/// The C# `LanguageModule`: grammar, chunk rules, project markers, and LSP server spec for `.cs` files.
///
/// - The Rust `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`/
///   `CONTAINER_KINDS` constants have no C# section to port, so this table is
///   derived directly from `tree-sitter-c-sharp`'s `src/node-types.json`,
///   following the same shape as the ported Java table since the two
///   languages' grammars are close cousins: `method_declaration` and
///   `constructor_declaration` map to `.method`; `class_declaration`,
///   `interface_declaration`, `struct_declaration`, `enum_declaration`, and
///   `record_declaration` map to `.type`; `delegate_declaration` (a named
///   callback type) also maps to `.type`.
/// - `containerNodeKinds` covers the type-declaring kinds above that host
///   member declarations (`class_declaration`, `interface_declaration`,
///   `struct_declaration`) plus `namespace_declaration`, C#'s analogue of
///   the Rust `CONTAINER_KINDS` constant's `namespace_definition` entry.
/// - `projectMarkers` are ported from `swissarmyhammer-project-detection`'s
///   `PROJECT_TYPE_SPECS` entry for `ProjectType::CSharp` (`*.csproj`,
///   `*.sln`).
/// - `languageServer` is ported from `builtin/lsp/omnisharp.yaml`.
public enum CSharpLanguage: LanguageModule {
    /// The language identifier (`"csharp"`).
    public static let name = "csharp"

    /// File extensions this module handles, without a leading dot: `["cs"]`.
    public static let fileExtensions = ["cs"]

    /// The tree-sitter-c-sharp grammar entry point used to parse `.cs` source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_c_sharp())

    /// Definition node kind → meta-type mapping.
    ///
    /// `method_declaration` and `constructor_declaration` map to `.method`;
    /// `class_declaration`, `interface_declaration`, `struct_declaration`,
    /// `enum_declaration`, and `record_declaration` map to `.type`;
    /// `delegate_declaration` (a named callback type) also maps to `.type`.
    public static let chunkKinds: [String: SymbolMetaType] = [
        "method_declaration": .method,
        "constructor_declaration": .method,
        "class_declaration": .type,
        "interface_declaration": .type,
        "struct_declaration": .type,
        "enum_declaration": .type,
        "record_declaration": .type,
        "delegate_declaration": .type,
    ]

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// Class, interface, struct, and namespace declarations provide this
    /// naming context without being chunked themselves.
    public static let containerNodeKinds: Set<String> = [
        "class_declaration",
        "interface_declaration",
        "struct_declaration",
        "namespace_declaration",
    ]

    /// Marker files that identify a C# project: `*.csproj` or `*.sln`.
    public static let projectMarkers: [ProjectMarker] = [
        .glob("*.csproj"),
        .glob("*.sln"),
    ]

    /// The C# language server spec (`omnisharp`).
    public static let languageServer: ServerSpec? = ServerSpec(
        command: "omnisharp",
        languageIDs: [name],
        installHint: "Install OmniSharp"
    )
}
