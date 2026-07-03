import SwiftTreeSitter
import TreeSitterTSX

/// The TSX `LanguageModule`: grammar, chunk rules, project markers, and LSP server spec for `.tsx` files.
///
/// TSX is TypeScript's syntax extended with JSX. Its grammar ships as a
/// second target (`TreeSitterTSX`) bundled inside the same upstream
/// `tree-sitter-typescript` package/product as `TreeSitterTypeScript` (see
/// `Package.swift`'s `treeSitterTypeScriptPackage` comment) — there is no
/// separate `tree-sitter-tsx` repository. Chunk kinds, container kinds,
/// project markers, and the language server spec are otherwise identical to
/// `TypeScriptLanguage` — see that type's doc comment for the porting
/// rationale.
public enum TSXLanguage: LanguageModule {
    /// The language identifier (`"tsx"`).
    public static let name = "tsx"

    /// File extensions this module handles, without a leading dot: `["tsx"]`.
    public static let fileExtensions = ["tsx"]

    /// The tree-sitter-tsx grammar entry point used to parse `.tsx` source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_tsx())

    /// Definition node kind → meta-type mapping, shared with TypeScript and JavaScript.
    public static let chunkKinds: [String: SymbolMetaType] = SharedChunkKinds.javaScriptFamily

    /// Node kinds that provide naming context for nested symbols' symbol_path, shared with TypeScript and JavaScript.
    public static let containerNodeKinds: Set<String> = SharedChunkKinds.javaScriptFamilyContainers

    /// Marker files that identify a Node.js/TSX project: `package.json`, shared with TypeScript and JavaScript.
    public static let projectMarkers: [ProjectMarker] = SharedProjectMarkers.nodeJs

    /// The shared `typescript-language-server` spec (also used by TypeScript and JavaScript).
    public static let languageServer: ServerSpec? = SharedServerSpecs.typeScriptFamily
}
