import SwiftTreeSitter
import TreeSitterMarkdown

/// The Markdown `LanguageModule`: grammar and chunk rules for `.md`/`.markdown`/`.mdx` files.
///
/// - The Rust `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`
///   constant has no Markdown section. `chunkKinds` maps `section` — a
///   heading (ATX `#`/setext-underlined) together with the content and
///   nested subsections that follow it, up to the next heading of equal or
///   higher level — to `.other`, so a document's sections are chunked as
///   units. There is no closer analogue to `.function`, `.method`, or
///   `.type` for a documentation format with no callable or type
///   declarations.
/// - `containerNodeKinds` is `section`: sections nest recursively (a `##`
///   subsection is a child of its enclosing `#` section), so a nested
///   section's symbol_path is qualified by its ancestor sections.
/// - This module uses `tree_sitter_markdown()`, the block-level grammar
///   (headings, paragraphs, lists, code blocks). The upstream
///   `tree-sitter-markdown` repository ships a second, separate
///   `tree_sitter_markdown_inline()` grammar for inline markup (emphasis,
///   links, inline code) that individual block-level leaf nodes delegate to;
///   this module doesn't reference it; see `Package.swift`'s dependency
///   comment for why depending on the bundled `TreeSitterMarkdown` product is
///   enough to import just the block-level module.
/// - `projectMarkers` is empty: `swissarmyhammer-project-detection`'s
///   `ProjectType` enum has no Markdown variant — a `.md` file doesn't
///   identify a whole project the way `Cargo.toml` or `pyproject.toml` does.
/// - `languageServer` is `nil`: this is a tree-sitter-only module (no
///   Markdown entry in `builtin/lsp/*.yaml`).
public enum MarkdownLanguage: LanguageModule {
    /// The language identifier (`"markdown"`).
    public static let name = "markdown"

    /// File extensions this module handles, without a leading dot: `["md", "markdown", "mdx"]`.
    public static let fileExtensions = ["md", "markdown", "mdx"]

    /// The tree-sitter-markdown (block-level) grammar entry point used to parse `.md` source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_markdown())

    /// Definition node kind → meta-type mapping.
    ///
    /// `section` (a heading together with the content and nested
    /// subsections that follow it) maps to `.other`: Markdown has no
    /// function, method, or type declaration to chunk, but a document's
    /// sections are still meaningful units worth indexing.
    public static let chunkKinds: [String: SymbolMetaType] = [
        "section": .other
    ]

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// `section` provides this naming context for its nested subsections,
    /// since sections nest recursively by heading level.
    public static let containerNodeKinds: Set<String> = [
        "section"
    ]

    /// Marker files that identify a Markdown project.
    ///
    /// Empty: `swissarmyhammer-project-detection`'s `ProjectType` enum has no
    /// Markdown variant.
    public static let projectMarkers: [ProjectMarker] = []

    /// Always `nil`: this is a tree-sitter-only module with no LSP server.
    public static let languageServer: ServerSpec? = nil
}
