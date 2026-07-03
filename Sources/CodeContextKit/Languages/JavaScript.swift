import SwiftTreeSitter
import TreeSitterJavaScript

/// The JavaScript `LanguageModule`: grammar, chunk rules, project markers, and LSP server spec for `.js` files.
///
/// Chunk kinds, container kinds, project markers, and the language server
/// spec are shared with `TypeScriptLanguage` and `TSXLanguage` — see that
/// type's doc comment for the porting rationale.
public enum JavaScriptLanguage: LanguageModule {
    /// The language identifier (`"javascript"`).
    public static let name = "javascript"

    /// File extensions this module handles, without a leading dot: `["js"]`.
    public static let fileExtensions = ["js"]

    /// The tree-sitter-javascript grammar entry point used to parse `.js` source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_javascript())

    /// Definition node kind → meta-type mapping, shared with TypeScript and TSX.
    public static let chunkKinds: [String: SymbolMetaType] = SharedChunkKinds.javaScriptFamily

    /// Node kinds that provide naming context for nested symbols' symbol_path, shared with TypeScript and TSX.
    public static let containerNodeKinds: Set<String> = SharedChunkKinds.javaScriptFamilyContainers

    /// Marker files that identify a Node.js/JavaScript project: `package.json`, shared with TypeScript and TSX.
    public static let projectMarkers: [ProjectMarker] = SharedProjectMarkers.nodeJs

    /// The shared `typescript-language-server` spec (also used by TypeScript and TSX).
    public static let languageServer: ServerSpec? = SharedServerSpecs.typeScriptFamily
}
