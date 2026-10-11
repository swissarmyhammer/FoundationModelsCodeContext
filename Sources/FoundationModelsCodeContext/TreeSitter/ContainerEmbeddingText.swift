import Foundation
import SwiftTreeSitter

extension Chunker {
    /// The version of the rules that make the embed text of a chunk (see
    /// `SemanticChunk.embeddingText`).
    ///
    /// `TreeSitterWorker` stores this version in the index metadata. When the
    /// stored version is not this version, the worker chunks each file again
    /// and embeds each chunk again, one time. Increase this number for each
    /// change of the embed-text rules: the vector length does not change,
    /// thus the dimension check cannot see such a change.
    ///
    /// Version 0 is the rules before container summaries: each chunk embedded
    /// its full text. Version 1 is the rules before wrapper summaries: a
    /// wrapper chunk of a container (the `decorated_definition` of a Python
    /// class) embedded its full text.
    static let embeddingTextVersion = 2
}

/// Makes the embed text of a container chunk: a summary of the container,
/// not its full text.
///
/// A container (a class, a struct, a protocol, an `impl`) is a chunk, and each
/// of its members is also a chunk. Thus the full text of a container holds the
/// member text a second time, and a large class is a very long embedder
/// input. The summary has, one part for each line group:
///
/// 1. The declaration: the node text from its start to the start of its
///    `body` field.
/// 2. The doc text, from the location that `LanguageModule.docTextLocation`
///    gives.
/// 3. The declaration of each member chunk, on one line for each member.
///
/// An empty part is not in the summary.
///
/// A wrapper chunk of a container, for example the `decorated_definition` of
/// a Python class, also embeds a summary. Its declaration starts at the
/// wrapper, thus the decorators are in it. Its doc text and its member
/// declarations are those of the container that it wraps.
enum ContainerEmbeddingText {
    /// The field that holds the body of a definition in most grammars.
    private static let bodyFieldName = "body"

    /// The field that holds the wrapped definition of a wrapper node that has
    /// no body of its own, for example the `decorated_definition` of
    /// tree-sitter-python. The declaration of such a node ends at the body of
    /// the definition that it wraps.
    private static let wrappedDefinitionFieldName = "definition"

    /// The end of the node kind of each comment node: `comment`,
    /// `line_comment`, `block_comment`, `multiline_comment`.
    private static let commentNodeKindSuffix = "comment"

    /// The separator between the parts of a summary, and between the lines
    /// of the doc text.
    private static let lineSeparator = "\n"

    /// Makes the summary of a container chunk.
    ///
    /// - Parameters:
    ///   - node: The node of the container chunk.
    ///   - memberDeclarations: The one-line declaration of each member chunk,
    ///     in source order (see `memberDeclaration(of:in:)`).
    ///   - source: The full text of the file that `node` is in.
    ///   - module: The language module that gives the doc-text location.
    /// - Returns: The declaration, the doc text and the member declarations,
    ///   one part after the other, with a newline between two parts.
    static func summary(
        of node: Node,
        memberDeclarations: [String],
        in source: String,
        module: any LanguageModule.Type
    ) -> String {
        let parts = [declaration(of: node, in: source), docText(of: node, in: source, location: module.docTextLocation)]
        return (parts + memberDeclarations)
            .filter { !$0.isEmpty }
            .joined(separator: lineSeparator)
    }

    /// Gives the declaration of a member chunk on one line: the declaration
    /// (see `declaration(of:in:)`) with each run of white space, line breaks
    /// included, changed to one space.
    ///
    /// - Parameters:
    ///   - node: The node of the member chunk.
    ///   - source: The full text of the file that `node` is in.
    /// - Returns: The declaration on one line.
    static func memberDeclaration(of node: Node, in source: String) -> String {
        declaration(of: node, in: source)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Gives the declaration of a definition node: the node text from its
    /// start to the start of its body, with no white space at the end.
    ///
    /// The body is the `body` field of the node, or the `body` field of the
    /// definition that the node wraps (see `wrappedDefinitionFieldName`). A
    /// node with no body (a Rust `const` item, a Rust `mod` with no block)
    /// gives the first line of its text.
    ///
    /// - Parameters:
    ///   - node: The definition node.
    ///   - source: The full text of the file that `node` is in.
    /// - Returns: The declaration text.
    private static func declaration(of node: Node, in source: String) -> String {
        let nodeRange = node.range
        guard let body = body(of: node) else {
            let text = text(in: nodeRange, of: source)
            return firstLine(of: text)
        }
        let declarationRange = NSRange(location: nodeRange.location, length: body.range.location - nodeRange.location)
        return trimmingTrailingWhitespace(text(in: declarationRange, of: source))
    }

    /// Gives the definition that a wrapper node wraps (see
    /// `wrappedDefinitionFieldName`), or `nil` when `node` wraps no
    /// definition.
    ///
    /// - Parameter node: The node that can be a wrapper.
    /// - Returns: The wrapped definition node, or `nil`.
    static func wrappedDefinition(of node: Node) -> Node? {
        node.child(byFieldName: wrappedDefinitionFieldName)
    }

    /// Gives the body node of a definition node, or `nil` when it has none.
    private static func body(of node: Node) -> Node? {
        node.child(byFieldName: bodyFieldName)
            ?? wrappedDefinition(of: node)?.child(byFieldName: bodyFieldName)
    }

    /// Gives the doc text of a definition node from `location`.
    ///
    /// - Parameters:
    ///   - node: The definition node.
    ///   - source: The full text of the file that `node` is in.
    ///   - location: The location of the doc text in the language of `node`.
    /// - Returns: The doc text, or an empty string when there is none.
    private static func docText(of node: Node, in source: String, location: DocTextLocation) -> String {
        switch location {
        case .precedingComments:
            return precedingComments(of: node, in: source)
        case .bodyStringStatement(let statementKind, let stringKind):
            return bodyString(of: node, in: source, statementKind: statementKind, stringKind: stringKind)
        }
    }

    /// Gives the comment nodes directly before `node`, in source order, one
    /// comment for each line group.
    ///
    /// A comment is directly before the node below it when no blank line is
    /// between them. The first comment that is not directly before the node
    /// below it ends the doc text.
    private static func precedingComments(of node: Node, in source: String) -> String {
        var comments: [String] = []
        var nodeBelow = node
        while let candidate = nodeBelow.previousSibling, isComment(candidate),
            lastRow(of: candidate) + 1 >= nodeBelow.pointRange.lowerBound.row
        {
            comments.append(trimmingTrailingWhitespace(text(in: candidate.range, of: source)))
            nodeBelow = candidate
        }
        return comments.reversed().joined(separator: lineSeparator)
    }

    /// Gives the string literal of the first statement of the body of `node`,
    /// when that statement holds only a string literal.
    ///
    /// Comment nodes at the start of the body are not statements.
    ///
    /// - Parameters:
    ///   - node: The definition node.
    ///   - source: The full text of the file that `node` is in.
    ///   - statementKind: The node kind of a statement that holds one
    ///     expression.
    ///   - stringKind: The node kind of a string literal.
    /// - Returns: The text of the string literal, or an empty string.
    private static func bodyString(of node: Node, in source: String, statementKind: String, stringKind: String) -> String {
        guard let body = body(of: node),
            let statement = firstNamedChild(of: body, where: { !isComment($0) }),
            statement.nodeType == statementKind,
            statement.namedChildCount == 1,
            let literal = statement.namedChild(at: 0),
            literal.nodeType == stringKind
        else {
            return ""
        }
        return text(in: literal.range, of: source)
    }

    /// Gives the first named child of `node` that `isIncluded` accepts.
    private static func firstNamedChild(of node: Node, where isIncluded: (Node) -> Bool) -> Node? {
        (0..<node.namedChildCount).lazy
            .compactMap { node.namedChild(at: $0) }
            .first(where: isIncluded)
    }

    /// `true` when the node kind of `node` is a comment kind.
    private static func isComment(_ node: Node) -> Bool {
        node.nodeType?.hasSuffix(commentNodeKindSuffix) ?? false
    }

    /// Gives the last row that holds text of `node`.
    ///
    /// Some grammars put the line break at the end of a line comment into the
    /// comment node (tree-sitter-rust does). Then the node ends at column 0 of
    /// the next row, and that row holds no text of the node.
    private static func lastRow(of node: Node) -> UInt32 {
        let range = node.pointRange
        let endsAtLineStart = range.upperBound.column == 0 && range.upperBound.row > range.lowerBound.row
        return endsAtLineStart ? range.upperBound.row - 1 : range.upperBound.row
    }

    /// Gives the text of `source` in the UTF-16 range `range`, or an empty
    /// string when the range is not in `source`.
    private static func text(in range: NSRange, of source: String) -> String {
        Range(range, in: source).map { String(source[$0]) } ?? ""
    }

    /// Gives the first line of `text`, with no white space at the end.
    private static func firstLine(of text: String) -> String {
        trimmingTrailingWhitespace(String(text.prefix { !$0.isNewline }))
    }

    /// Gives `text` with no white space and no line break at the end.
    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        String(text.reversed().drop(while: \.isWhitespace).reversed())
    }
}
