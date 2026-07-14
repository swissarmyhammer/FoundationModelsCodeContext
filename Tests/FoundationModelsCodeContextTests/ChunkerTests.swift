import SwiftTreeSitter
import Testing

@testable import FoundationModelsCodeContext

/// A `LanguageModule` with no tree-sitter grammar, used only to exercise
/// `Chunker`'s nil-language guard — every real module in `Languages.all`
/// always has a non-nil `treeSitterLanguage` (see
/// `LanguageModuleTests.everyModuleHasATreeSitterLanguage`), so this fake
/// stands in for the case that guard actually protects against.
private enum NoGrammarLanguage: LanguageModule {
    static let name = "no-grammar"
    static let fileExtensions: [String] = []
    static let treeSitterLanguage: Language? = nil
    static let chunkKinds: [String: SymbolMetaType] = [:]
    static let containerNodeKinds: Set<String> = []
    static let projectMarkers: [ProjectMarker] = []
    static let languageServer: ServerSpec? = nil
}

/// Golden chunk-set tests for `Chunker`: symbol_path qualification
/// (container node kinds + name-field heuristics) and per-language kind
/// classification, for the Swift, Rust, and Python fixtures called out in
/// the task's acceptance criteria — plus range/text extraction and the
/// unparseable-input edge cases.
struct ChunkerTests {
    @Test
    func swiftMethodNestedInStructIsQualifiedByContainerName() throws {
        let source = """
        struct Struct {
            func method() {}
        }

        func freeFunction() {}
        """
        let file = SourceFile(relativePath: "Sample.swift", contents: source)

        let chunks = Chunker.chunk(file: file, module: SwiftLanguage.self)

        let structChunk = try #require(chunks.first { $0.symbolPath == "Struct" })
        #expect(structChunk.kind == .type)

        let methodChunk = try #require(chunks.first { $0.symbolPath == "Struct.method" })
        // tree-sitter-swift has no separate node kind for a method versus a
        // free function (both parse as `function_declaration`), and
        // `SwiftLanguage.chunkKinds` maps that one kind to `.function`
        // unconditionally (see the LanguageModule task's documented design
        // decision) — so a nested method still reports `.function`, not
        // `.method`.
        #expect(methodChunk.kind == .function)

        let freeFunctionChunk = try #require(chunks.first { $0.symbolPath == "freeFunction" })
        #expect(freeFunctionChunk.kind == .function)
    }

    @Test
    func rustImplItemContainerQualifiesNestedFunctionWithImplPrefix() throws {
        let source = """
        impl Foo {
            fn bar() {}
        }
        """
        let file = SourceFile(relativePath: "sample.rs", contents: source)

        let chunks = Chunker.chunk(file: file, module: RustLanguage.self)

        let implChunk = try #require(chunks.first { $0.symbolPath == "impl Foo" })
        #expect(implChunk.kind == .other)

        let methodChunk = try #require(chunks.first { $0.symbolPath == "impl Foo.bar" })
        #expect(methodChunk.kind == .function)
    }

    @Test
    func pythonMethodNestedInClassIsQualifiedByContainerName() throws {
        let source = """
        class Foo:
            def bar(self):
                pass

        def baz():
            pass
        """
        let file = SourceFile(relativePath: "sample.py", contents: source)

        let chunks = Chunker.chunk(file: file, module: PythonLanguage.self)

        let classChunk = try #require(chunks.first { $0.symbolPath == "Foo" })
        #expect(classChunk.kind == .type)

        let methodChunk = try #require(chunks.first { $0.symbolPath == "Foo.bar" })
        #expect(methodChunk.kind == .function)

        let freeFunctionChunk = try #require(chunks.first { $0.symbolPath == "baz" })
        #expect(freeFunctionChunk.kind == .function)
    }

    @Test
    func chunkRangeAndTextMatchTheSourceNode() throws {
        let source = "func topLevel() {}\n"
        let file = SourceFile(relativePath: "Sample.swift", contents: source)

        let chunks = Chunker.chunk(file: file, module: SwiftLanguage.self)

        let chunk = try #require(chunks.first)
        #expect(chunk.text == "func topLevel() {}")
        #expect(chunk.filePath == "Sample.swift")
        #expect(chunk.startByte == 0)
        #expect(chunk.endByte == chunk.text.utf8.count)
        #expect(chunk.startLine == 0)
        #expect(chunk.endLine == 0)
    }

    @Test
    func chunkByteOffsetsAreUTF8BytesNotUTF16CodeUnits() throws {
        // A doc comment containing multi-byte UTF-8 characters (each "é" is
        // 2 UTF-8 bytes / 1 UTF-16 code unit, each "🎉" is 4 UTF-8 bytes / 2
        // UTF-16 code units) precedes the chunked node, so a UTF-16-code-unit
        // offset and a true UTF-8 byte offset would disagree about where it
        // starts if the conversion were wrong.
        let preamble = "// café 🎉 note\n"
        let functionText = "func topLevel() {}"
        let source = preamble + functionText + "\n"
        let file = SourceFile(relativePath: "Sample.swift", contents: source)

        let chunks = Chunker.chunk(file: file, module: SwiftLanguage.self)

        let chunk = try #require(chunks.first)
        #expect(chunk.text == functionText)
        #expect(chunk.startByte == preamble.utf8.count)
        #expect(chunk.endByte == preamble.utf8.count + functionText.utf8.count)
        // The preamble's UTF-16 code unit count is smaller than its UTF-8
        // byte count (the non-ASCII characters each cost more UTF-8 bytes
        // than UTF-16 code units) — asserting they differ pins down that
        // this fixture actually exercises the encoding mismatch, not just
        // an ASCII string where both counts would coincide.
        #expect(preamble.utf8.count != preamble.utf16.count)
    }

    @Test
    func emptySourceProducesNoChunks() {
        let file = SourceFile(relativePath: "Empty.swift", contents: "")
        let chunks = Chunker.chunk(file: file, module: SwiftLanguage.self)
        #expect(chunks.isEmpty)
    }

    @Test
    func moduleWithNoTreeSitterLanguageProducesNoChunks() {
        let file = SourceFile(relativePath: "sample.txt", contents: "anything at all")
        let chunks = Chunker.chunk(file: file, module: NoGrammarLanguage.self)
        #expect(chunks.isEmpty)
    }
}
