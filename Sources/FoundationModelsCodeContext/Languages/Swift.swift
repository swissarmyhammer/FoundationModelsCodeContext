import SwiftTreeSitter
import TreeSitterSwift

/// The Swift `LanguageModule`: grammar, chunk rules, project markers, and LSP server spec for `.swift` files.
///
/// - Chunk kinds are ported from the Swift section of the Rust
///   `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`
///   constant (`function_declaration`, `class_declaration`,
///   `struct_declaration`, `enum_declaration`, `protocol_declaration`).
/// - `containerNodeKinds` extends past the Rust `CONTAINER_KINDS` constant's
///   single Swift-applicable entry (`class_declaration`) to cover `struct`,
///   `enum`, `protocol`, and `extension` declarations too, since methods
///   commonly live in all of them, not only classes — a deliberate,
///   documented deviation in service of `containerNodeKinds`'s stated
///   purpose (qualifying nested symbols' `symbol_path`, plan.md "Language
///   modules (strategy pattern)").
/// - `projectMarkers` are ported from `swissarmyhammer-project-detection`'s
///   `PROJECT_TYPE_SPECS` entry for `ProjectType::Swift`.
/// - `languageServer` is ported from `builtin/lsp/sourcekit-lsp.yaml`.
public enum SwiftLanguage: LanguageModule {
    /// The language identifier (`"swift"`).
    public static let name = "swift"

    /// File extensions this module handles, without a leading dot: `["swift"]`.
    public static let fileExtensions = ["swift"]

    /// The tree-sitter-swift grammar entry point used to parse `.swift` source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_swift())

    /// Definition node kind → meta-type mapping.
    ///
    /// `function_declaration` maps to `.function`; `class_declaration`,
    /// `struct_declaration`, `enum_declaration`, and `protocol_declaration`
    /// map to `.type`.
    public static let chunkKinds: [String: SymbolMetaType] = [
        "function_declaration": .function,
        "class_declaration": .type,
        "struct_declaration": .type,
        "enum_declaration": .type,
        "protocol_declaration": .type,
    ]

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// Class, struct, enum, protocol, and extension declarations provide
    /// this naming context without being chunked themselves.
    public static let containerNodeKinds: Set<String> = [
        "class_declaration",
        "struct_declaration",
        "enum_declaration",
        "protocol_declaration",
        "extension_declaration",
    ]

    /// Marker files that identify a Swift project.
    ///
    /// `Package.swift`, or a `*.xcodeproj`/`*.xcworkspace` bundle.
    public static let projectMarkers: [ProjectMarker] = [
        .fileName("Package.swift"),
        .glob("*.xcodeproj"),
        .glob("*.xcworkspace"),
    ]

    /// The Swift language server spec (`sourcekit-lsp`).
    ///
    /// Typed as optional per the protocol to allow tree-sitter-only modules
    /// with no server; Swift always provides one.
    public static let languageServer: ServerSpec? = ServerSpec(
        command: "sourcekit-lsp",
        languageIDs: [name],
        installHint: "Install Xcode or Swift toolchain"
    )
}
