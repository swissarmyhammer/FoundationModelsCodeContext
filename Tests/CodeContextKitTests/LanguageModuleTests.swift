import Testing

@testable import CodeContextKit

/// Tests for the `LanguageModule` strategy protocol, its supporting value
/// types, and the `Languages.all` registry — extension→module lookup and
/// per-module chunk-kind/meta-type spot checks. See plan.md "Language
/// modules (strategy pattern)".
struct LanguageModuleTests {
    @Test
    func registryContainsAllThreeV1Modules() {
        let names = Set(Languages.all.map { $0.name })
        #expect(names == ["swift", "rust", "python"])
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
    func serverSpecDefaultsMatchPlan() {
        let spec = ServerSpec(command: "rust-analyzer", languageIDs: ["rust"], installHint: "install it")
        #expect(spec.startupTimeout == .seconds(30))
        #expect(spec.healthCheckInterval == .seconds(60))
        #expect(spec.args.isEmpty)
    }

    @Test
    func projectMarkersUseFileNameAndGlobCases() {
        #expect(RustLanguage.projectMarkers.contains(.fileName("Cargo.toml")))
        #expect(SwiftLanguage.projectMarkers.contains(.glob("*.xcodeproj")))
        #expect(PythonLanguage.projectMarkers.contains(.fileName("pyproject.toml")))
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
    func everyModuleHasATreeSitterLanguage() {
        for module in Languages.all {
            #expect(module.treeSitterLanguage != nil)
        }
    }

    @Test
    func everyModuleDeclaresALanguageServer() {
        // All three v1 modules (swift/rust/python) have an LSP server spec;
        // tree-sitter-only modules (added later) would leave this nil.
        for module in Languages.all {
            #expect(module.languageServer != nil)
        }
    }
}
