/// Chunk-kind and container-kind tables shared by more than one `LanguageModule`.
///
/// The TypeScript, TSX, and JavaScript grammars share the definition-level
/// node kinds ported from the Rust `swissarmyhammer-treesitter/src/chunk.rs`
/// `EMBEDDABLE_NODE_KINDS`/`CONTAINER_KINDS` combined "JavaScript/TypeScript"
/// section: TSX's grammar is a superset of TypeScript's that adds JSX nodes,
/// and TypeScript's is a superset of JavaScript's that adds type syntax, but
/// none of the added nodes change which node kinds are definitions. Declaring
/// the table once here, rather than three copies, keeps the same
/// single-source-of-truth guarantee for chunk-kind data that
/// `SharedServerSpecs` gives the LSP server specs.
enum SharedChunkKinds {
    /// Definition node kind → meta-type mapping for JavaScript, TypeScript, and TSX.
    ///
    /// `function_declaration`, `function_expression`, `arrow_function`, and
    /// `generator_function_declaration` map to `.function`; `method_definition`
    /// (only found inside a class body) maps to `.method`; `class_declaration`
    /// maps to `.type`; `export_statement` wraps whichever declaration it
    /// exports and can't be classified from its own node kind alone, so it
    /// maps to `.other` — the same reasoning `PythonLanguage` uses for
    /// `decorated_definition`.
    static let javaScriptFamily: [String: SymbolMetaType] = [
        "function_declaration": .function,
        "function_expression": .function,
        "arrow_function": .function,
        "generator_function_declaration": .function,
        "method_definition": .method,
        "class_declaration": .type,
        "export_statement": .other,
    ]

    /// Node kinds that provide naming context for nested symbols'
    /// symbol_path across JavaScript, TypeScript, and TSX: class
    /// declarations.
    static let javaScriptFamilyContainers: Set<String> = [
        "class_declaration",
    ]
}
