import Foundation
import SwiftTreeSitter
import TreeSitter

// `CodeEntities` — the public API that reads the code entities of one source
// file for a semantic diff. It parses the file with tree-sitter and reads its
// entities.
//
// A port of the extraction part of `parser/plugins/code/mod.rs` in
// `../swissarmyhammer/crates/swissarmyhammer-sem/src/`: the struct
// `CodeParserPlugin`, `parse_code`, and `ParsedCode::entities`. The parts of
// that file for duplication, commented code, the test census, and the public
// surface are not ported.
//
// The Rust code keeps one parser for each language and thread. A
// SwiftTreeSitter `Parser` is a class that is not `Sendable`, thus this port
// makes one parser for each parse.
//
// The parse reads the UTF-8 bytes of the file (`TSInputEncodingUTF8`), thus
// each byte offset of a node is a UTF-8 offset, as in Rust. The `parse(_:)`
// call of SwiftTreeSitter reads UTF-16 and gives UTF-16 offsets.

/// Reads the code entities of one source file, for a semantic diff.
///
/// The values are a port of the code plugin of the Rust
/// `swissarmyhammer-sem` crate. Each id, hash, and line is equal to the value
/// of that crate for the same file.
public enum CodeEntities {

    /// The file extensions that ``entities(in:filePath:)`` reads, in
    /// lowercase with a leading dot (for example `.rs`), in the order of the
    /// Rust `get_all_code_extensions`.
    public static var supportedFileExtensions: [String] { CodeLanguageConfig.allExtensions }

    /// The code entities of one file: `extract_entities` in
    /// `parser/plugins/code/mod.rs`.
    ///
    /// The extension of `filePath` selects the language. A file whose
    /// extension is not in ``supportedFileExtensions``, or that the grammar
    /// does not parse, gives no entity.
    ///
    /// The result has one entity for each declaration, in the order of the
    /// walk. A nested declaration comes after the entity that holds it, and
    /// its ``CodeEntity/parentID`` is the id of that entity.
    ///
    /// - Parameters:
    ///   - content: The whole text of the file.
    ///   - filePath: The path of the file. It selects the language, and each
    ///     entity id starts with it.
    /// - Returns: The entities of the file, or an empty list.
    public static func entities(in content: String, filePath: String) -> [CodeEntity] {
        guard let config = CodeLanguageConfig.config(forExtension: fileExtension(of: filePath)) else { return [] }
        let source = Array(content.utf8)
        guard let root = parse(source, config: config) else { return [] }
        return CodeEntityExtractor.extractEntities(
            root: root, source: source, filePath: filePath, vocabulary: config.vocabulary)
    }

    /// The content hash of `content`: `content_hash` in `utils/hash.rs`.
    ///
    /// Each ``CodeEntity/contentHash`` is this hash of the entity content. A
    /// caller that hashes other entities (for example JSON keys) uses this
    /// function, thus the two kinds of entity use one hash.
    ///
    /// - Parameter content: The text to hash, as UTF-8 bytes.
    /// - Returns: The 64-bit XXH3 hash as 16 lowercase hexadecimal characters.
    public static func contentHash(_ content: String) -> String {
        SemanticHash.contentHash(content)
    }

    /// The first `length` characters of ``contentHash(_:)``: `short_hash` in
    /// `utils/hash.rs`. A length above 16 gives the full hash.
    ///
    /// - Parameters:
    ///   - content: The text to hash.
    ///   - length: The number of characters to keep.
    /// - Returns: The prefix of the content hash.
    public static func shortHash(_ content: String, length: Int) -> String {
        SemanticHash.shortHash(content, length: length)
    }

    /// The extension of a path in lowercase with a leading dot, or an empty
    /// string when the file name has no extension: the extension rules of
    /// the Rust `ParserRegistry`.
    ///
    /// A file name that starts with its only dot (for example `.bashrc`) has
    /// no extension.
    ///
    /// - Parameter filePath: A file path.
    /// - Returns: The extension, for example `.rs`.
    static func fileExtension(of filePath: String) -> String {
        let fileName = filePath.split(separator: "/").last { $0 != "." }
        guard let fileName, fileName != "..",
            let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex
        else { return "" }
        return "." + fileName[fileName.index(after: dot)...].lowercased()
    }

    /// The root of the parse of `source` with the grammar of `config`, or
    /// `nil` when the parse makes no tree: `parse_code` in
    /// `parser/plugins/code/mod.rs`.
    ///
    /// The Rust `parse_code` writes a warning and gives `None` when the
    /// parser does not accept the grammar (an ABI version that the runtime
    /// does not support). Here that is a programmer error, not a state that
    /// a file can cause: `Package.swift` pins the runtime and each grammar,
    /// and the tests load each grammar of ``CodeLanguageConfig/all``. Thus
    /// this port stops with a precondition failure.
    private static func parse(_ source: [UInt8], config: CodeLanguageConfig) -> TreeSitterSyntaxNode? {
        let parser = Parser()
        do {
            try parser.setLanguage(config.language)
        } catch {
            preconditionFailure("the tree-sitter runtime does not accept the \(config.id) grammar: \(error)")
        }
        let data = Data(source)
        let tree = parser.parse(tree: nil as Tree?, encoding: TSInputEncodingUTF8) { offset, _ in
            offset < data.count ? data[offset...] : nil
        }
        return tree?.rootNode.map(TreeSitterSyntaxNode.init(node:))
    }
}

/// One node of a tree-sitter parse, as ``CodeEntityExtractor`` and
/// ``SemanticHash`` read it.
///
/// Each SwiftTreeSitter `Node` holds a reference to its tree, thus the tree
/// stays alive while a node of it is in use.
struct TreeSitterSyntaxNode: CodeSyntaxNode {

    /// The tree-sitter node.
    let node: Node

    var kind: String { node.nodeType ?? "" }

    var startByte: Int { Int(node.byteRange.lowerBound) }

    var endByte: Int { Int(node.byteRange.upperBound) }

    var startRow: Int { Int(node.pointRange.lowerBound.row) }

    var endRow: Int { Int(node.pointRange.upperBound.row) }

    var children: [TreeSitterSyntaxNode] {
        (0..<node.childCount).compactMap { node.child(at: $0) }.map(Self.init(node:))
    }

    var namedChildren: [TreeSitterSyntaxNode] {
        (0..<node.namedChildCount).compactMap { node.namedChild(at: $0) }.map(Self.init(node:))
    }

    func child(byFieldName name: String) -> TreeSitterSyntaxNode? {
        node.child(byFieldName: name).map(Self.init(node:))
    }
}
