import SwiftTreeSitter
import TreeSitterSwift

/// The Swift `LanguageModule`: grammar, chunk rules, project markers, and
/// LSP server spec for `.swift` files.
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
    public static let name = "swift"

    public static let fileExtensions = ["swift"]

    public static let treeSitterLanguage: Language? = Language(tree_sitter_swift())

    public static let chunkKinds: [String: SymbolMetaType] = [
        "function_declaration": .function,
        "class_declaration": .type,
        "struct_declaration": .type,
        "enum_declaration": .type,
        "protocol_declaration": .type,
    ]

    public static let containerNodeKinds: Set<String> = [
        "class_declaration",
        "struct_declaration",
        "enum_declaration",
        "protocol_declaration",
        "extension_declaration",
    ]

    public static let projectMarkers: [ProjectMarker] = [
        .fileName("Package.swift"),
        .glob("*.xcodeproj"),
        .glob("*.xcworkspace"),
    ]

    public static let languageServer: ServerSpec? = ServerSpec(
        command: "sourcekit-lsp",
        languageIds: ["swift"],
        installHint: "Install Xcode or Swift toolchain"
    )
}
