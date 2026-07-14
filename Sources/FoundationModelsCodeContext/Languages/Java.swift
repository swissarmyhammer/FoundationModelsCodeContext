import SwiftTreeSitter
import TreeSitterJava

/// The Java `LanguageModule`: grammar, chunk rules, project markers, and LSP server spec for `.java` files.
///
/// - Chunk kinds are ported from the Java section of the Rust
///   `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`
///   constant. `method_declaration` and `constructor_declaration` map to
///   `.method` (both are callable members bound to the enclosing type);
///   `class_declaration`, `interface_declaration`, and `enum_declaration`
///   map to `.type`.
/// - `containerNodeKinds` extends past the Rust `CONTAINER_KINDS` constant's
///   two Java-applicable entries (`class_declaration`, `interface_declaration`)
///   to also cover `enum_declaration`, since Java enums may implement
///   interfaces and declare their own methods — the same deviation
///   `SwiftLanguage` already makes for its own container set.
/// - `projectMarkers` combine `swissarmyhammer-project-detection`'s
///   `PROJECT_TYPE_SPECS` entries for `ProjectType::JavaMaven` (`pom.xml`)
///   and `ProjectType::JavaGradle` (`build.gradle`, `build.gradle.kts`); the
///   Swift port has one `LanguageModule` per language rather than per build
///   system.
/// - `languageServer` is ported from `builtin/lsp/jdtls.yaml`.
public enum JavaLanguage: LanguageModule {
    /// The language identifier (`"java"`).
    public static let name = "java"

    /// File extensions this module handles, without a leading dot: `["java"]`.
    public static let fileExtensions = ["java"]

    /// The tree-sitter-java grammar entry point used to parse `.java` source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_java())

    /// Definition node kind → meta-type mapping.
    ///
    /// `method_declaration` and `constructor_declaration` map to `.method`
    /// (both are callable members bound to the enclosing type);
    /// `class_declaration`, `interface_declaration`, and `enum_declaration`
    /// map to `.type`.
    public static let chunkKinds: [String: SymbolMetaType] = [
        "method_declaration": .method,
        "constructor_declaration": .method,
        "class_declaration": .type,
        "interface_declaration": .type,
        "enum_declaration": .type,
    ]

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// Class, interface, and enum declarations provide this naming context
    /// without being chunked themselves.
    public static let containerNodeKinds: Set<String> = [
        "class_declaration",
        "interface_declaration",
        "enum_declaration",
    ]

    /// Marker files that identify a Java project: `pom.xml` (Maven) or
    /// `build.gradle`/`build.gradle.kts` (Gradle).
    public static let projectMarkers: [ProjectMarker] = [
        .fileName("pom.xml"),
        .fileName("build.gradle"),
        .fileName("build.gradle.kts"),
    ]

    /// The Java language server spec (`jdtls`).
    public static let languageServer: ServerSpec? = ServerSpec(
        command: "jdtls",
        languageIDs: [name],
        installHint: "Install Eclipse JDT Language Server"
    )
}
