import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for ``CodeEntities`` and ``CodeLanguageConfig`` — the port of
/// `parser/plugins/code/mod.rs` (the extraction part) and
/// `parser/plugins/code/languages.rs` in
/// `../swissarmyhammer/crates/swissarmyhammer-sem/src/`.
///
/// These tests parse real source with the tree-sitter grammars of the
/// package. They check the routing of a file to its grammar and the parts of
/// a parse that the golden suite (`CodeEntitiesGoldenTests`) does not name:
/// the parent of a nested entity, the line numbers, and the UTF-8 byte
/// offsets.
@Suite("CodeEntitiesTests")
struct CodeEntitiesTests {

    /// The entities that ``CodeEntities`` reads from `content` at `filePath`.
    private static func entities(_ content: String, at filePath: String) -> [CodeEntity] {
        CodeEntities.entities(in: content, filePath: filePath)
    }

    // MARK: Routing

    /// Each code extension selects a language, in any case, as `get_plugin`
    /// lowercases the extension.
    @Test(
        "each code extension selects a language",
        arguments: [
            "src/app.ts", "src/App.tsx", "src/app.js", "src/App.jsx", "src/module.mjs", "src/module.cjs",
            "app/main.py", "src/main.rs", "cmd/main.go", "Sources/App.swift", "SRC/MAIN.RS", "src/Main.java",
            "lib/list.c", "include/list.h", "src/app.cpp", "src/app.cc", "src/app.cxx", "include/app.hpp",
            "include/app.hh", "include/app.hxx", "src/Program.cs", "lib/app.rb", "public/index.php",
            "lib/app.ex", "test/app_test.exs", "scripts/deploy.sh",
        ])
    func eachCodeExtensionSelectsALanguage(filePath: String) {
        let fileExtension = CodeEntities.fileExtension(of: filePath)
        #expect(CodeEntities.supportedFileExtensions.contains(fileExtension))
        #expect(CodeLanguageConfig.config(forExtension: fileExtension) != nil)
    }

    /// The extension of a path follows the rules of the Rust
    /// `ParserRegistry`: lowercase, with a leading dot, and none for a file
    /// name that starts with its only dot.
    @Test(
        "the extension of a path follows the Rust registry rules",
        arguments: [
            ("src/Main.RS", ".rs"), ("a/b.tar.gz", ".gz"), (".bashrc", ""), ("Makefile", ""),
            ("dir/.", ""), ("..", ""), ("dir/file.", "."),
        ] as [(String, String)])
    func theExtensionOfAPathFollowsTheRustRegistryRules(filePath: String, fileExtension: String) {
        #expect(CodeEntities.fileExtension(of: filePath) == fileExtension)
    }

    /// No language of the table claims `.f90` or the other extensions of
    /// that grammar: the Rust table has Fortran, but no SwiftPM grammar
    /// exists for it.
    @Test(
        "no language claims an f90 file",
        arguments: [".f90", ".f95", ".f03", ".f08", ".f", ".for"])
    func noLanguageClaimsAnF90File(fileExtension: String) {
        #expect(CodeLanguageConfig.config(forExtension: fileExtension) == nil)
        #expect(Self.entities("program p\nend program p\n", at: "src/solver" + fileExtension).isEmpty)
    }

    /// The API claims the extensions of each language of the table, in the
    /// order of the table.
    @Test("the API claims the extension of each language")
    func theAPIClaimsTheExtensionOfEachLanguage() {
        #expect(
            CodeEntities.supportedFileExtensions == [
                ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".py", ".go", ".rs", ".java", ".c", ".h", ".cpp",
                ".cc", ".cxx", ".hpp", ".hh", ".hxx", ".rb", ".cs", ".php", ".swift", ".ex", ".exs", ".sh",
            ])
    }

    /// The table gives each extension its language, and no language to an
    /// extension that it does not list. C comes before C++ in the table,
    /// thus `.h` is C, as in `languages.rs`. Bash claims `.sh` only, thus
    /// `.bash` has no language, as in `languages.rs`. JavaScript claims
    /// `.jsx`: no JSX language is in the table.
    @Test(
        "the language table maps each extension to its language",
        arguments: [
            (".ts", "typescript"), (".tsx", "tsx"), (".js", "javascript"), (".jsx", "javascript"),
            (".mjs", "javascript"), (".cjs", "javascript"), (".py", "python"), (".rs", "rust"), (".go", "go"),
            (".swift", "swift"), (".java", "java"), (".c", "c"), (".h", "c"),
            (".cpp", "cpp"), (".cc", "cpp"), (".cxx", "cpp"), (".hpp", "cpp"), (".hh", "cpp"), (".hxx", "cpp"),
            (".cs", "csharp"), (".rb", "ruby"), (".php", "php"), (".ex", "elixir"), (".exs", "elixir"),
            (".sh", "bash"), (".bash", nil), (".txt", nil),
        ] as [(String, String?)])
    func theLanguageTableMapsEachExtension(fileExtension: String, languageID: String?) {
        #expect(CodeLanguageConfig.config(forExtension: fileExtension)?.id == languageID)
    }

    /// A file with an extension that no language claims gives no entity.
    @Test("an unknown extension gives no entity")
    func anUnknownExtensionGivesNoEntity() {
        #expect(Self.entities("fn main() {}\n", at: "file.unknown_ext").isEmpty)
    }

    /// An empty file gives no entity.
    @Test("an empty source gives no entity")
    func anEmptySourceGivesNoEntity() {
        #expect(Self.entities("", at: "empty.rs").isEmpty)
    }

    // MARK: Parse

    /// The methods of a Rust `impl` are entities of that `impl`, as in the
    /// Rust test `test_rust_impl_nested_methods`.
    @Test("the methods of a Rust impl are entities of the impl")
    func theMethodsOfARustImplAreEntitiesOfTheImpl() {
        let source = """
            pub struct Counter {
                count: u32,
            }

            impl Counter {
                pub fn new() -> Self {
                    Counter { count: 0 }
                }
            }
            """

        let entities = Self.entities(source, at: "counter.rs")

        #expect(entities.map(\.id) == [
            "counter.rs::struct::Counter", "counter.rs::impl::Counter", "counter.rs::counter.rs::impl::Counter::new",
        ])
        #expect(entities.map(\.parentID) == [nil, nil, "counter.rs::impl::Counter"])
    }

    /// The lines of an entity are the 1-based rows of its node.
    @Test("the lines of an entity are the rows of its node")
    func theLinesOfAnEntityAreTheRowsOfItsNode() throws {
        let source = "package main\n\nfunc Area(w, h float64) float64 {\n\treturn w * h\n}\n"

        let entity = try #require(Self.entities(source, at: "area.go").first)

        #expect(entity.name == "Area")
        #expect(entity.startLine == 3)
        #expect(entity.endLine == 5)
    }

    /// The parse reads UTF-8, thus the text of an entity after a multi-byte
    /// character is the exact text of its node.
    @Test("an entity after a multi-byte character has its exact text")
    func anEntityAfterAMultiByteCharacterHasItsExactText() throws {
        let function = "func greet() -> String {\n    \"héllo\"\n}"
        let source = "// Café ☕️ crème\n" + function + "\n"

        let entity = try #require(Self.entities(source, at: "greet.swift").first)

        #expect(entity.name == "greet")
        #expect(entity.content == function)
        #expect(entity.contentHash == CodeEntities.contentHash(function))
    }

    /// Each code entity has a structural hash and no metadata, as in Rust.
    @Test("each code entity has a structural hash and no metadata")
    func eachCodeEntityHasAStructuralHashAndNoMetadata() {
        let entities = Self.entities("fn a() {}\nfn b() {}\n", at: "lib.rs")

        #expect(entities.count == 2)
        #expect(entities.allSatisfy { $0.structuralHash?.count == 16 && $0.metadata == nil })
    }

    /// The public short hash is the prefix of the public content hash.
    @Test("the short hash is the prefix of the content hash")
    func theShortHashIsThePrefixOfTheContentHash() {
        #expect(CodeEntities.shortHash("abc", length: 8) == String(CodeEntities.contentHash("abc").prefix(8)))
    }
}
