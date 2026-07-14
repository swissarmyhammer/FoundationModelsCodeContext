import SwiftTreeSitter
import TreeSitterTypeScript

/// The TypeScript `LanguageModule`: grammar, chunk rules, project markers, and LSP server spec for `.ts` files.
///
/// - Chunk kinds and container kinds are shared with `JavaScriptLanguage` and
///   `TSXLanguage` via `SharedChunkKinds.javaScriptFamily` — see that type's
///   doc comment for the porting rationale.
/// - `projectMarkers` are ported from `swissarmyhammer-project-detection`'s
///   `PROJECT_TYPE_SPECS` entry for `ProjectType::NodeJs` (`package.json`);
///   the Rust crate doesn't distinguish TypeScript from plain JavaScript/
///   Node.js projects, so all three modules share this one marker.
/// - `languageServer` is `SharedServerSpecs.typeScriptFamily`, shared with
///   `JavaScriptLanguage` and `TSXLanguage` — see that type's doc comment.
public enum TypeScriptLanguage: LanguageModule {
    /// The language identifier (`"typescript"`).
    public static let name = "typescript"

    /// File extensions this module handles, without a leading dot: `["ts"]`.
    public static let fileExtensions = ["ts"]

    /// The tree-sitter-typescript grammar entry point used to parse `.ts` source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_typescript())

    /// Definition node kind → meta-type mapping, shared with JavaScript and TSX.
    public static let chunkKinds: [String: SymbolMetaType] = SharedChunkKinds.javaScriptFamily

    /// Node kinds that provide naming context for nested symbols' symbol_path, shared with JavaScript and TSX.
    public static let containerNodeKinds: Set<String> = SharedChunkKinds.javaScriptFamilyContainers

    /// Marker files that identify a Node.js/TypeScript project: `package.json`, shared with JavaScript and TSX.
    public static let projectMarkers: [ProjectMarker] = SharedProjectMarkers.nodeJs

    /// The shared `typescript-language-server` spec (also used by JavaScript and TSX).
    public static let languageServer: ServerSpec? = SharedServerSpecs.typeScriptFamily
}
