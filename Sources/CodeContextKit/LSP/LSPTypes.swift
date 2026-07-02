import Foundation

/// A document identifier in LSP wire format, e.g. `file:///repo/src/main.rs`.
///
/// Wraps the raw URI string rather than parsing it into a `URL`: the LSP
/// specification treats `DocumentUri` as an opaque string that servers echo
/// back verbatim, and round-tripping through `URL` can normalize percent
/// escaping in ways some servers don't expect.
public struct DocumentURI: Sendable, Equatable, Hashable, Codable {
    /// The raw URI string, e.g. `file:///repo/src/main.rs`.
    public let value: String

    /// Wraps a raw URI string as a `DocumentURI`.
    public init(_ value: String) {
        self.value = value
    }

    /// Decodes a `DocumentURI` from its raw JSON string representation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(String.self)
    }

    /// Encodes this `DocumentURI` as its raw JSON string representation.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A zero-based line/character position inside a text document.
///
/// Mirrors the LSP `Position` shape exactly (see the LSP 3.17
/// specification's "Position" section); `character` is a UTF-16 code unit
/// offset per the spec, not a grapheme or Unicode scalar count.
public struct Position: Sendable, Equatable, Hashable, Codable {
    /// The zero-based line number.
    public let line: Int

    /// The zero-based UTF-16 code unit offset within `line`.
    public let character: Int

    /// Creates a zero-based line/character position.
    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

/// A start/end span inside a text document.
///
/// Named `LSPRange` rather than `Range` to avoid shadowing
/// `Swift.Range<Bound>` throughout this single-target package — every other
/// file in `CodeContextKit` would otherwise need to qualify the standard
/// library type as `Swift.Range`. This mirrors the LSP `Range` shape.
public struct LSPRange: Sendable, Equatable, Hashable, Codable {
    /// The range's start position, inclusive.
    public let start: Position

    /// The range's end position, exclusive.
    public let end: Position

    /// Creates a start/end span inside a text document.
    public init(start: Position, end: Position) {
        self.start = start
        self.end = end
    }
}

/// A location inside a text document: a URI plus the span within it.
public struct Location: Sendable, Equatable, Hashable, Codable {
    /// The document this location refers to.
    public let uri: DocumentURI

    /// The span within `uri`.
    public let range: LSPRange

    /// Creates a location inside a text document.
    public init(uri: DocumentURI, range: LSPRange) {
        self.uri = uri
        self.range = range
    }
}

/// The severity of a diagnostic, per the LSP `DiagnosticSeverity` enum.
public enum DiagnosticSeverity: Int, Sendable, Equatable, Codable {
    /// Reports an error.
    case error = 1

    /// Reports a warning.
    case warning = 2

    /// Reports an informational message.
    case information = 3

    /// Reports a hint. Also the lenient-parsing default for a missing or
    /// unrecognized severity value (see `Diagnostic.init(from:)`).
    case hint = 4
}

/// A single diagnostic reported against a range of a text document.
///
/// Decoding is deliberately lenient, matching `swissarmyhammer-lsp`'s
/// `diagnostics.rs`: `range` and `message` are required (a missing or
/// malformed one throws, which callers use to skip just that array element
/// — see `DiagnosticsParsing` in `Wire.swift`), while `severity` defaults to
/// `.hint` when absent or unrecognized, and `code`/`source` are dropped
/// (not thrown) when present with an unexpected JSON type.
public struct Diagnostic: Sendable, Equatable {
    /// The span of the document this diagnostic applies to.
    public let range: LSPRange

    /// The diagnostic's severity.
    ///
    /// Defaults to `.hint` when the server omits it or sends an
    /// unrecognized value.
    public let severity: DiagnosticSeverity

    /// The server's diagnostic code (e.g. `"E0308"`), if any.
    ///
    /// The wire value may be a JSON string or number; a number is converted
    /// with `String(_:)`. Any other JSON type is dropped to `nil`.
    public let code: String?

    /// The tool that produced this diagnostic (e.g. `"rustc"`), if any.
    public let source: String?

    /// The human-readable diagnostic message.
    public let message: String

    /// Creates a single diagnostic.
    public init(range: LSPRange, severity: DiagnosticSeverity, code: String?, source: String?, message: String) {
        self.range = range
        self.severity = severity
        self.code = code
        self.source = source
        self.message = message
    }
}

extension Diagnostic: Codable {
    private enum CodingKeys: String, CodingKey {
        case range
        case severity
        case code
        case source
        case message
    }

    /// Leniently decodes a diagnostic, per this type's documented rules.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        range = try container.decode(LSPRange.self, forKey: .range)
        message = try container.decode(String.self, forKey: .message)

        let rawSeverity: Int? = (try? container.decodeIfPresent(Int.self, forKey: .severity)) ?? nil
        if let rawSeverity, let mapped = DiagnosticSeverity(rawValue: rawSeverity) {
            severity = mapped
        } else {
            severity = .hint
        }

        let stringCode: String? = (try? container.decodeIfPresent(String.self, forKey: .code)) ?? nil
        let intCode: Int? = (try? container.decodeIfPresent(Int.self, forKey: .code)) ?? nil
        if let stringCode {
            code = stringCode
        } else if let intCode {
            code = String(intCode)
        } else {
            code = nil
        }

        source = (try? container.decodeIfPresent(String.self, forKey: .source)) ?? nil
    }

    /// Encodes a diagnostic, including its resolved `severity`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(range, forKey: .range)
        try container.encode(severity, forKey: .severity)
        try container.encodeIfPresent(code, forKey: .code)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encode(message, forKey: .message)
    }
}

/// The kind of a symbol, per the LSP `SymbolKind` enum.
///
/// Public because it is required by the shared, public `CallHierarchyItem`
/// type below; the wire-only `DocumentSymbol`/`SymbolInformation` payload
/// structs in `Wire.swift` also use it internally.
public enum SymbolKind: Int, Sendable, Equatable, Codable {
    /// A file.
    case file = 1
    /// A module.
    case module = 2
    /// A namespace.
    case namespace = 3
    /// A package.
    case package = 4
    /// A class.
    case `class` = 5
    /// A method.
    case method = 6
    /// A property.
    case property = 7
    /// A field.
    case field = 8
    /// A constructor.
    case constructor = 9
    /// An enum.
    case `enum` = 10
    /// An interface.
    case interface = 11
    /// A function.
    case function = 12
    /// A variable.
    case variable = 13
    /// A constant.
    case constant = 14
    /// A string literal.
    case string = 15
    /// A numeric literal.
    case number = 16
    /// A boolean literal.
    case boolean = 17
    /// An array literal.
    case array = 18
    /// An object literal.
    case object = 19
    /// A key in a map or object literal.
    case key = 20
    /// A null literal.
    case null = 21
    /// An enum member.
    case enumMember = 22
    /// A struct.
    case `struct` = 23
    /// An event.
    case event = 24
    /// An operator.
    case `operator` = 25
    /// A type parameter.
    case typeParameter = 26
}

/// One entry in an LSP call hierarchy — a symbol plus its declaration span.
///
/// Returned by `textDocument/prepareCallHierarchy` and echoed back as the
/// `item` parameter to `callHierarchy/incomingCalls`/`outgoingCalls`.
///
/// `tags` and `data` from the LSP `CallHierarchyItem` shape are omitted:
/// this package never reads or round-trips them.
public struct CallHierarchyItem: Sendable, Equatable, Codable {
    /// The symbol's name, as displayed by the server.
    public let name: String

    /// The symbol's kind.
    public let kind: SymbolKind

    /// Extra detail about the symbol (e.g. a function signature), if any.
    public let detail: String?

    /// The document containing the symbol.
    public let uri: DocumentURI

    /// The symbol's full span, including its body.
    public let range: LSPRange

    /// The span of just the symbol's name, used for highlighting.
    public let selectionRange: LSPRange

    /// Creates a call hierarchy item.
    public init(name: String, kind: SymbolKind, detail: String?, uri: DocumentURI, range: LSPRange, selectionRange: LSPRange) {
        self.name = name
        self.kind = kind
        self.detail = detail
        self.uri = uri
        self.range = range
        self.selectionRange = selectionRange
    }
}
