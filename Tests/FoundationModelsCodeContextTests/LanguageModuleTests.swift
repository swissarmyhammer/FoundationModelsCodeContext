import SwiftTreeSitter
import Testing

@testable import FoundationModelsCodeContext

/// Tests for the `LanguageModule` strategy protocol, its supporting value
/// types, and the `Languages.all` registry — extension→module lookup and
/// per-module chunk-kind/meta-type spot checks. See plan.md "Language
/// modules (strategy pattern)".
struct LanguageModuleTests {
    /// Parses `source` with `language` and returns whether the resulting
    /// tree's root node is error-free.
    ///
    /// A grammar "resolves and parses a snippet" (this task's acceptance
    /// criteria) when `Parser.setLanguage` succeeds and the parsed root node
    /// reports no syntax error — the standard smoke test for a newly wired
    /// tree-sitter dependency.
    ///
    /// - Parameters:
    ///   - source: The source snippet to parse.
    ///   - language: The tree-sitter grammar to parse it with.
    /// - Returns: `true` if parsing succeeded and the root node has no error.
    private func parsesWithoutError(source: String, language: Language) throws -> Bool {
        let parser = Parser()
        try parser.setLanguage(language)
        guard let tree = parser.parse(source), let root = tree.rootNode else {
            return false
        }
        return !root.hasError
    }

    @Test
    func registryContainsAllV1Modules() {
        let names = Set(Languages.all.map { $0.name })
        #expect(
            names == [
                "swift", "rust", "python",
                "typescript", "tsx", "javascript", "go",
                "c", "cpp", "java", "csharp", "php",
                "sql", "json", "yaml", "markdown", "bash",
            ])
    }

    @Test
    func moduleForFileExtensionResolvesSwift() {
        #expect(Languages.module(forFileExtension: "swift")?.name == "swift")
    }

    @Test
    func moduleForFileExtensionResolvesRust() {
        #expect(Languages.module(forFileExtension: "rs")?.name == "rust")
    }

    @Test
    func moduleForFileExtensionResolvesPython() {
        #expect(Languages.module(forFileExtension: "py")?.name == "python")
    }

    @Test
    func moduleForFileExtensionReturnsNilForUnknownExtension() {
        #expect(Languages.module(forFileExtension: "cobol") == nil)
    }

    @Test
    func moduleForFileExtensionMatchesCaseInsensitively() {
        #expect(Languages.module(forFileExtension: "SWIFT")?.name == "swift")
        #expect(Languages.module(forFileExtension: "Rs")?.name == "rust")
    }

    @Test
    func moduleForFileExtensionResolvesEveryLspBackedV1Extension() {
        #expect(Languages.module(forFileExtension: "ts")?.name == "typescript")
        #expect(Languages.module(forFileExtension: "tsx")?.name == "tsx")
        #expect(Languages.module(forFileExtension: "js")?.name == "javascript")
        #expect(Languages.module(forFileExtension: "go")?.name == "go")
        #expect(Languages.module(forFileExtension: "c")?.name == "c")
        #expect(Languages.module(forFileExtension: "cpp")?.name == "cpp")
        #expect(Languages.module(forFileExtension: "java")?.name == "java")
        #expect(Languages.module(forFileExtension: "cs")?.name == "csharp")
        #expect(Languages.module(forFileExtension: "php")?.name == "php")
    }

    @Test
    func moduleForFileExtensionResolvesEveryTreeSitterOnlyFormatExtension() {
        #expect(Languages.module(forFileExtension: "sql")?.name == "sql")
        #expect(Languages.module(forFileExtension: "json")?.name == "json")
        #expect(Languages.module(forFileExtension: "yaml")?.name == "yaml")
        #expect(Languages.module(forFileExtension: "yml")?.name == "yaml")
        #expect(Languages.module(forFileExtension: "md")?.name == "markdown")
        #expect(Languages.module(forFileExtension: "sh")?.name == "bash")
    }

    @Test
    func swiftChunkKindsMapFunctionAndTypeKinds() {
        #expect(SwiftLanguage.chunkKinds["function_declaration"] == .function)
        #expect(SwiftLanguage.chunkKinds["struct_declaration"] == .type)
        #expect(SwiftLanguage.chunkKinds["class_declaration"] == .type)
        #expect(SwiftLanguage.chunkKinds["enum_declaration"] == .type)
        #expect(SwiftLanguage.chunkKinds["protocol_declaration"] == .type)
    }

    @Test
    func rustChunkKindsMapFunctionAndTypeKinds() {
        #expect(RustLanguage.chunkKinds["function_item"] == .function)
        #expect(RustLanguage.chunkKinds["struct_item"] == .type)
        #expect(RustLanguage.chunkKinds["enum_item"] == .type)
        #expect(RustLanguage.chunkKinds["trait_item"] == .type)
    }

    @Test
    func rustImplItemIsNotClassifiedAsAType() {
        // `impl_item` implements methods for an existing type; it doesn't
        // declare a new one, so it's `.other` rather than `.type`.
        #expect(RustLanguage.chunkKinds["impl_item"] == .other)
    }

    @Test
    func pythonChunkKindsMapFunctionAndTypeKinds() {
        #expect(PythonLanguage.chunkKinds["function_definition"] == .function)
        #expect(PythonLanguage.chunkKinds["class_definition"] == .type)
    }

    @Test
    func typeScriptChunkKindsMapFunctionMethodAndTypeKinds() {
        #expect(TypeScriptLanguage.chunkKinds["function_declaration"] == .function)
        #expect(TypeScriptLanguage.chunkKinds["method_definition"] == .method)
        #expect(TypeScriptLanguage.chunkKinds["class_declaration"] == .type)
    }

    @Test
    func tsxChunkKindsMatchTypeScript() {
        #expect(TSXLanguage.chunkKinds == TypeScriptLanguage.chunkKinds)
    }

    @Test
    func javaScriptChunkKindsMatchTypeScript() {
        #expect(JavaScriptLanguage.chunkKinds == TypeScriptLanguage.chunkKinds)
    }

    @Test
    func goChunkKindsMapFunctionMethodAndTypeKinds() {
        #expect(GoLanguage.chunkKinds["function_declaration"] == .function)
        #expect(GoLanguage.chunkKinds["method_declaration"] == .method)
        #expect(GoLanguage.chunkKinds["type_declaration"] == .type)
    }

    @Test
    func cChunkKindsMapFunctionAndTypeKinds() {
        #expect(CLanguage.chunkKinds["function_definition"] == .function)
        #expect(CLanguage.chunkKinds["struct_specifier"] == .type)
    }

    @Test
    func cppChunkKindsMapFunctionTypeAndNamespaceKinds() {
        #expect(CPPLanguage.chunkKinds["function_definition"] == .function)
        #expect(CPPLanguage.chunkKinds["class_specifier"] == .type)
        // A namespace declares a scope, not a type.
        #expect(CPPLanguage.chunkKinds["namespace_definition"] == .other)
    }

    @Test
    func javaChunkKindsMapMethodDeclarationToMethod() {
        #expect(JavaLanguage.chunkKinds["method_declaration"] == .method)
        #expect(JavaLanguage.chunkKinds["class_declaration"] == .type)
    }

    @Test
    func csharpChunkKindsMapClassDeclarationToType() {
        #expect(CSharpLanguage.chunkKinds["class_declaration"] == .type)
        #expect(CSharpLanguage.chunkKinds["method_declaration"] == .method)
    }

    @Test
    func phpChunkKindsMapFunctionMethodAndTypeKinds() {
        #expect(PHPLanguage.chunkKinds["function_definition"] == .function)
        #expect(PHPLanguage.chunkKinds["method_declaration"] == .method)
        #expect(PHPLanguage.chunkKinds["class_declaration"] == .type)
    }

    @Test
    func sqlChunkKindsMapCreateStatementsToFunctionAndTypeAnalogues() {
        #expect(SQLLanguage.chunkKinds["create_function"] == .function)
        #expect(SQLLanguage.chunkKinds["create_table"] == .type)
        #expect(SQLLanguage.chunkKinds["create_view"] == .type)
    }

    @Test
    func sqlChunkKindsHasNoCreateProcedureEntry() {
        // `tree-sitter-sql` v0.3.11 (the version this project's Rust sibling
        // pins) has no `create_procedure` rule — only a `keyword_procedure`
        // token and a `// TODO: procedure` comment in its grammar — so there
        // is deliberately no entry for it here, unlike the Rust
        // `chunk.rs` reference, which lists one that never matches.
        #expect(SQLLanguage.chunkKinds["create_procedure"] == nil)
    }

    @Test
    func jsonChunkKindsMapPairToOther() {
        #expect(JSONLanguage.chunkKinds["pair"] == .other)
    }

    @Test
    func yamlChunkKindsMapMappingPairsToOther() {
        #expect(YAMLLanguage.chunkKinds["block_mapping_pair"] == .other)
        #expect(YAMLLanguage.chunkKinds["flow_pair"] == .other)
    }

    @Test
    func markdownChunkKindsMapSectionToOther() {
        #expect(MarkdownLanguage.chunkKinds["section"] == .other)
    }

    @Test
    func bashChunkKindsMapFunctionDefinitionToFunction() {
        #expect(BashLanguage.chunkKinds["function_definition"] == .function)
    }

    @Test
    func serverSpecDefaultsMatchPlan() {
        let spec = ServerSpec(command: "rust-analyzer", languageIDs: ["rust"], installHint: "install it")
        #expect(spec.startupTimeout == .seconds(30))
        #expect(spec.healthCheckInterval == .seconds(60))
        #expect(spec.args.isEmpty)
    }

    @Test
    func typeScriptTsxAndJavaScriptShareOneServerSpec() {
        #expect(TypeScriptLanguage.languageServer == TSXLanguage.languageServer)
        #expect(TypeScriptLanguage.languageServer == JavaScriptLanguage.languageServer)
        #expect(TypeScriptLanguage.languageServer == SharedServerSpecs.typeScriptFamily)
    }

    @Test
    func typeScriptFamilyDedupesToOneCommand() {
        let typeScriptFamilyCommands: [String] = [
            TypeScriptLanguage.languageServer?.command,
            TSXLanguage.languageServer?.command,
            JavaScriptLanguage.languageServer?.command,
        ].compactMap { $0 }
        let commands = Set(typeScriptFamilyCommands)
        #expect(commands == ["typescript-language-server"])
    }

    @Test
    func cAndCppShareOneServerSpec() {
        #expect(CLanguage.languageServer == CPPLanguage.languageServer)
        #expect(CLanguage.languageServer == SharedServerSpecs.clangd)
    }

    @Test
    func cAndCppDedupeToOneCommand() {
        let cFamilyCommands: [String] = [
            CLanguage.languageServer?.command,
            CPPLanguage.languageServer?.command,
        ].compactMap { $0 }
        let commands = Set(cFamilyCommands)
        #expect(commands == ["clangd"])
    }

    @Test
    func projectMarkersUseFileNameAndGlobCases() {
        #expect(RustLanguage.projectMarkers.contains(.fileName("Cargo.toml")))
        #expect(SwiftLanguage.projectMarkers.contains(.glob("*.xcodeproj")))
        #expect(PythonLanguage.projectMarkers.contains(.fileName("pyproject.toml")))
        #expect(CSharpLanguage.projectMarkers.contains(.glob("*.csproj")))
    }

    @Test
    func everyLanguageServerSpecUsesThirtySecondStartupAndSixtySecondHealthCheck() {
        for module in Languages.all {
            guard let spec = module.languageServer else { continue }
            #expect(spec.startupTimeout == .seconds(30))
            #expect(spec.healthCheckInterval == .seconds(60))
        }
    }

    @Test
    func everyModuleHasATreeSitterLanguageExceptDocumentedGrammarGaps() {
        // Every module has a working grammar except `SQLLanguage`: its
        // upstream `tree-sitter-sql` grammar has no working SwiftPM package
        // (the generated `parser.c` isn't committed to git — see
        // `SQLLanguage`'s doc comment and the gap noted in `Languages.swift`),
        // so it deliberately declares `treeSitterLanguage: nil`.
        for module in Languages.all where module.name != "sql" {
            #expect(module.treeSitterLanguage != nil)
        }
    }

    @Test
    func sqlGrammarIsNilPendingAWorkingSwiftPMWrapper() {
        #expect(SQLLanguage.treeSitterLanguage == nil)
    }

    @Test
    func everyLspBackedModuleDeclaresALanguageServer() {
        // Every v1 LSP-backed module (three tree-sitter-only-at-first
        // swift/rust/python plus the eight LSP-backed ones added afterward)
        // has an LSP server spec; the five tree-sitter-only format modules
        // (sql, json, yaml, markdown, bash) added afterward intentionally
        // have none.
        let treeSitterOnlyFormats: Set<String> = ["sql", "json", "yaml", "markdown", "bash"]
        for module in Languages.all where !treeSitterOnlyFormats.contains(module.name) {
            #expect(module.languageServer != nil)
        }
    }

    @Test
    func everyTreeSitterOnlyFormatModuleHasNoLanguageServer() {
        #expect(SQLLanguage.languageServer == nil)
        #expect(JSONLanguage.languageServer == nil)
        #expect(YAMLLanguage.languageServer == nil)
        #expect(MarkdownLanguage.languageServer == nil)
        #expect(BashLanguage.languageServer == nil)
    }

    @Test
    func typeScriptGrammarParsesWithoutError() throws {
        let language = try #require(TypeScriptLanguage.treeSitterLanguage)
        #expect(try parsesWithoutError(source: "function greet(name: string): string { return name; }", language: language))
    }

    @Test
    func tsxGrammarParsesWithoutError() throws {
        let language = try #require(TSXLanguage.treeSitterLanguage)
        #expect(try parsesWithoutError(source: "function Greet() { return <div>Hi</div>; }", language: language))
    }

    @Test
    func javaScriptGrammarParsesWithoutError() throws {
        let language = try #require(JavaScriptLanguage.treeSitterLanguage)
        #expect(try parsesWithoutError(source: "function greet(name) { return name; }", language: language))
    }

    @Test
    func goGrammarParsesWithoutError() throws {
        let language = try #require(GoLanguage.treeSitterLanguage)
        #expect(try parsesWithoutError(source: "package main\nfunc main() {}\n", language: language))
    }

    @Test
    func cGrammarParsesWithoutError() throws {
        let language = try #require(CLanguage.treeSitterLanguage)
        #expect(try parsesWithoutError(source: "int add(int a, int b) { return a + b; }", language: language))
    }

    @Test
    func cppGrammarParsesWithoutError() throws {
        let language = try #require(CPPLanguage.treeSitterLanguage)
        #expect(try parsesWithoutError(source: "class Foo { public: void bar() {} };", language: language))
    }

    @Test
    func javaGrammarParsesWithoutError() throws {
        let language = try #require(JavaLanguage.treeSitterLanguage)
        #expect(try parsesWithoutError(source: "class Foo { void bar() {} }", language: language))
    }

    @Test
    func csharpGrammarParsesWithoutError() throws {
        let language = try #require(CSharpLanguage.treeSitterLanguage)
        #expect(try parsesWithoutError(source: "class Foo { void Bar() {} }", language: language))
    }

    @Test
    func phpGrammarParsesWithoutError() throws {
        let language = try #require(PHPLanguage.treeSitterLanguage)
        #expect(try parsesWithoutError(source: "<?php function greet($name) { return $name; } ?>", language: language))
    }

    @Test
    func jsonGrammarParsesWithoutError() throws {
        let language = try #require(JSONLanguage.treeSitterLanguage)
        #expect(try parsesWithoutError(source: #"{"key": "value"}"#, language: language))
    }

    @Test
    func yamlGrammarParsesWithoutError() throws {
        let language = try #require(YAMLLanguage.treeSitterLanguage)
        #expect(try parsesWithoutError(source: "key: value\n", language: language))
    }

    @Test
    func markdownGrammarParsesWithoutError() throws {
        let language = try #require(MarkdownLanguage.treeSitterLanguage)
        #expect(
            try parsesWithoutError(
                source: "# Title\n\nSome text.\n\n## Subsection\n\nMore text.\n", language: language))
    }

    @Test
    func bashGrammarParsesWithoutError() throws {
        let language = try #require(BashLanguage.treeSitterLanguage)
        #expect(try parsesWithoutError(source: "greet() {\n  echo \"hi\"\n}\n", language: language))
    }
}
