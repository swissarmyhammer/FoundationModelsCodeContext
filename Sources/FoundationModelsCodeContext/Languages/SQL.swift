import SwiftTreeSitter

/// The SQL `LanguageModule`: chunk rules and a documented grammar gap for `.sql` files.
///
/// - `treeSitterLanguage` is `nil`. The upstream grammar this project's Rust
///   sibling depends on (`DerekStride/tree-sitter-sql`, published to crates.io
///   as `tree-sitter-sequel` since crates.io reserves the `tree-sitter-sql`
///   name) has a root-level `Package.swift` manifest listing `src/parser.c`
///   and `src/scanner.c` as build sources, but `src/parser.c` — the generated
///   parser — is not committed to git at any tagged release or on `main`;
///   only the hand-written `src/scanner.c` is checked in. The generated
///   parser is produced by `tree-sitter generate` and bundled only into the
///   npm/crates.io release tarballs, which SwiftPM (a plain `git` checkout)
///   never fetches. Adding it as an SPM dependency as-is fails to build. Per
///   `Languages.swift`'s stated policy, this gap is documented here — with
///   `treeSitterLanguage: nil` — rather than standing up a wrapper package
///   that vendors generated sources ourselves. See `Package.swift` for the
///   corresponding dependency-list note.
/// - Chunk kinds are still populated so the table is ready the day a working
///   SwiftPM wrapper appears: `create_function` maps to `.function`;
///   `create_table` and `create_view` map to `.type`. These node kind names
///   were verified directly against the single root-level `grammar.js` in
///   `DerekStride/tree-sitter-sql` at the `v0.3.11` tag (the version this
///   project's Rust sibling pins) rather than copied from the Rust
///   `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`
///   constant: that constant's SQL section lists
///   `create_function_statement`/`create_table_statement`/
///   `create_view_statement`, but no such `_statement`-suffixed rules exist
///   in the grammar it's meant to describe — only `create_function`,
///   `create_table`, and `create_view` do. That looks like a latent bug in
///   the Rust reference; it isn't ported here.
/// - There is deliberately no `create_procedure` entry, even though the Rust
///   `chunk.rs` reference lists one: at `v0.3.11`, `grammar.js` has no
///   `create_procedure` rule at all — only a `keyword_procedure` token (used
///   inside other statements) and a `// TODO: procedure` comment — so CREATE
///   PROCEDURE isn't a supported statement in this pinned version, and an
///   entry for it would never match a real parse-tree node kind.
/// - `containerNodeKinds` is empty: none of the Rust `CONTAINER_KINDS`
///   constant's entries are SQL-specific.
/// - `projectMarkers` is empty: `swissarmyhammer-project-detection`'s
///   `ProjectType` enum has no SQL variant — a `.sql` file doesn't identify a
///   whole project the way `Cargo.toml` or `pyproject.toml` does.
/// - `languageServer` is `nil`: this is a tree-sitter-only module (no SQL
///   entry in `builtin/lsp/*.yaml`).
public enum SQLLanguage: LanguageModule {
    /// The language identifier (`"sql"`).
    public static let name = "sql"

    /// File extensions this module handles, without a leading dot: `["sql"]`.
    public static let fileExtensions = ["sql"]

    /// Always `nil`: see this type's doc comment for why `tree-sitter-sql`
    /// has no working SwiftPM package.
    public static let treeSitterLanguage: Language? = nil

    /// Definition node kind → meta-type mapping.
    ///
    /// `create_function` maps to `.function`; `create_table` and
    /// `create_view` map to `.type`, since both declare a persistent
    /// structure rather than a callable routine. There is no
    /// `create_procedure` entry: see this type's doc comment for why.
    public static let chunkKinds: [String: SymbolMetaType] = [
        "create_function": .function,
        "create_table": .type,
        "create_view": .type,
    ]

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// Empty: none of the Rust `CONTAINER_KINDS` constant's entries are
    /// SQL-specific, and SQL's `create_*` statements aren't nested inside one
    /// another.
    public static let containerNodeKinds: Set<String> = []

    /// Marker files that identify a SQL project.
    ///
    /// Empty: `swissarmyhammer-project-detection`'s `ProjectType` enum has no
    /// SQL variant.
    public static let projectMarkers: [ProjectMarker] = []

    /// Always `nil`: this is a tree-sitter-only module with no LSP server.
    public static let languageServer: ServerSpec? = nil
}
