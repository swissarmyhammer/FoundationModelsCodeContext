import SwiftTreeSitter
import TreeSitterGo

/// The Go `LanguageModule`: grammar, chunk rules, project markers, and LSP server spec for `.go` files.
///
/// - Chunk kinds are ported from the Go section of the Rust
///   `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`
///   constant. `function_declaration` maps to `.function`; `method_declaration`
///   (a function with an explicit receiver parameter) maps to `.method`;
///   `type_declaration` and its child `type_spec` both map to `.type`.
/// - `containerNodeKinds` is empty: none of the Rust `CONTAINER_KINDS`
///   constant's entries are Go-specific, and Go has no real container for
///   chunked definitions — methods are declared at the top level with an
///   explicit receiver parameter (`func (r Receiver) Method()`) rather than
///   nested inside the receiver type's body.
/// - `projectMarkers` are ported from `swissarmyhammer-project-detection`'s
///   `PROJECT_TYPE_SPECS` entry for `ProjectType::Go`.
/// - `languageServer` is ported from `builtin/lsp/gopls.yaml`.
public enum GoLanguage: LanguageModule {
    /// The language identifier (`"go"`).
    public static let name = "go"

    /// File extensions this module handles, without a leading dot: `["go"]`.
    public static let fileExtensions = ["go"]

    /// The tree-sitter-go grammar entry point used to parse `.go` source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_go())

    /// Definition node kind → meta-type mapping.
    ///
    /// `function_declaration` maps to `.function`; `method_declaration` (a
    /// function with an explicit receiver parameter) maps to `.method`;
    /// `type_declaration` and its child `type_spec` both map to `.type`.
    public static let chunkKinds: [String: SymbolMetaType] = [
        "function_declaration": .function,
        "method_declaration": .method,
        "type_declaration": .type,
        "type_spec": .type,
    ]

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// Empty: Go methods carry their receiver type as a parameter rather
    /// than nesting inside the receiver type's declaration, so there is no
    /// container node to qualify a symbol_path with.
    public static let containerNodeKinds: Set<String> = []

    /// The marker file that identifies a Go project: `go.mod`.
    public static let projectMarkers: [ProjectMarker] = [
        .fileName("go.mod"),
    ]

    /// The Go language server spec (`gopls`).
    public static let languageServer: ServerSpec? = ServerSpec(
        command: "gopls",
        languageIDs: [name],
        installHint: "Install gopls: go install github.com/golang/tools/gopls@latest"
    )
}
