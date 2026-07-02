import Foundation

/// `Content-Length`-framed JSON-RPC 2.0 wire codec for talking to a
/// language-server child process over stdio.
///
/// Everything in this file is intentionally non-public: per plan.md "LSP
/// subsystem", the JSON-RPC wire format — framing, envelopes, method
/// strings, ids — is a private implementation detail of the process-backed
/// server connection. Callers above the connection program against a typed
/// Swift API and never see a method string, an id, or raw JSON. Only the
/// shared LSP value types in `LSPTypes.swift` (`Position`, `Location`,
/// `Diagnostic`, `DiagnosticSeverity`, `CallHierarchyItem`, `DocumentURI`,
/// `LSPRange`, `SymbolKind`) are public, because a later task's typed
/// `LanguageServerConnection` protocol returns them directly.
enum JSONRPCFraming {
    /// Wraps a JSON payload in `Content-Length` framing for the wire.
    ///
    /// The length is a **byte** count (`payload.count`), not a character
    /// count, so multi-byte UTF-8 payloads frame correctly.
    static func frame(payload: Data) -> Data {
        var framed = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        framed.append(payload)
        return framed
    }

    /// Decodes one JSON-RPC response body, verifying it answers `expectedID`.
    ///
    /// - Throws: `WireError.serverError` if the response carries a JSON-RPC
    ///   `error` object; `WireError.idMismatch` if its `id` doesn't match
    ///   `expectedID`; a `DecodingError` if `result` doesn't match `Result`.
    static func decodeResult<Result: Decodable>(as resultType: Result.Type, from data: Data, expectedID: Int) throws -> Result {
        let envelope = try JSONDecoder().decode(JSONRPCResponseEnvelope<Result>.self, from: data)
        guard envelope.id == expectedID else {
            throw WireError.idMismatch(expected: expectedID, actual: envelope.id)
        }
        if let error = envelope.error {
            throw WireError.serverError(code: error.code, message: error.message)
        }
        guard let result = envelope.result else {
            throw WireError.missingResult
        }
        return result
    }

    /// Peeks at a raw message's `id` and `method` without decoding a typed
    /// payload, to route it to a pending request (has `id`, no `method`) or
    /// a server-initiated notification (has `method`, no `id`).
    static func peek(message data: Data) throws -> JSONRPCEnvelopePeek {
        try JSONDecoder().decode(JSONRPCEnvelopePeek.self, from: data)
    }
}

/// Errors raised by the private JSON-RPC wire codec.
enum WireError: Error, Equatable {
    /// A response's `id` didn't match the request it was expected to answer.
    case idMismatch(expected: Int, actual: Int?)

    /// The server returned a JSON-RPC `error` object instead of a result.
    case serverError(code: Int, message: String)

    /// A response had neither an `error` nor a decodable `result`.
    case missingResult
}

/// Incrementally decodes `Content-Length`-framed JSON-RPC messages from an
/// arbitrarily chunked byte stream.
///
/// Feed bytes as they arrive from the child process's stdout via
/// `append(bytes:)`; each call returns the messages (possibly zero, one, or
/// several) that became complete as a result, with header bytes stripped.
/// Bytes for an incomplete header or body are retained across calls, so
/// callers can feed data one read-buffer at a time (or even one byte at a
/// time) without losing messages.
struct JSONRPCMessageDecoder {
    /// Bytes received but not yet resolved into a complete message.
    private var buffer = Data()

    /// The `\r\n\r\n` sequence separating headers from the JSON body.
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Appends newly received bytes and returns every message completed as
    /// a result.
    mutating func append(bytes: Data) -> [Data] {
        buffer.append(bytes)

        var messages: [Data] = []
        while let message = extractNextMessage() {
            messages.append(message)
        }
        return messages
    }

    /// Extracts and removes one complete message from the front of
    /// `buffer`, or returns `nil` if the buffered bytes don't yet contain a
    /// full header-plus-body message.
    private mutating func extractNextMessage() -> Data? {
        guard let headerEnd = buffer.range(of: Self.headerTerminator) else {
            return nil
        }
        let headerBytes = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerBytes, encoding: .utf8) else {
            return nil
        }
        guard let contentLength = Self.parseContentLength(from: headerText) else {
            return nil
        }

        let bodyStart = headerEnd.upperBound
        let bodyEnd = bodyStart + contentLength
        guard bodyEnd <= buffer.endIndex else {
            // Body hasn't fully arrived yet; wait for more bytes.
            return nil
        }

        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return body
    }

    /// Parses the `Content-Length` header value out of a raw header block.
    ///
    /// Other headers (e.g. `Content-Type`) are present in some transcripts
    /// and are ignored.
    private static func parseContentLength(from headerText: String) -> Int? {
        for line in headerText.split(separator: "\r\n") {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare("Content-Length") == .orderedSame else { continue }
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            return Int(value)
        }
        return nil
    }
}

// MARK: - JSON-RPC envelopes

/// A JSON-RPC 2.0 request sent to the server: expects a matching response.
struct JSONRPCRequestEnvelope<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

/// A JSON-RPC 2.0 notification sent to the server: fire-and-forget, no `id`
/// and no response expected.
struct JSONRPCNotificationEnvelope<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: Params
}

/// A JSON-RPC 2.0 response received from the server, generic over the
/// decoded shape of `result`.
///
/// Decodes `result` with a hand-written `init(from:)` rather than the
/// synthesized one: the synthesized decoder calls `decodeIfPresent`, which
/// special-cases a JSON `null` by returning Swift `nil` *before* asking
/// `Result`'s own `Decodable` conformance to run — fine when `Result` is a
/// concrete type, but wrong when a caller instantiates `Result` itself as
/// `Optional<X>` (as `decodeResult(as:from:expectedID:)` does for LSP
/// methods whose result is nullable): the `null` must reach `Optional<X>`'s
/// own decoding so it produces `.some(.none)` — "the key was present and
/// its value validly decodes to no `X`" — rather than being flattened away
/// before `Result` ever sees it.
struct JSONRPCResponseEnvelope<Result: Decodable>: Decodable {
    let id: Int?
    let result: Result?
    let error: JSONRPCErrorPayload?

    private enum CodingKeys: String, CodingKey {
        case id
        case result
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        error = try container.decodeIfPresent(JSONRPCErrorPayload.self, forKey: .error)
        if container.contains(.result) {
            result = try container.decode(Result.self, forKey: .result)
        } else {
            result = nil
        }
    }
}

/// The `error` object of a JSON-RPC 2.0 error response.
struct JSONRPCErrorPayload: Decodable {
    let code: Int
    let message: String
}

/// A minimal, untyped peek at a raw JSON-RPC message: enough to tell a
/// response (`id` present) from a server-initiated notification (`method`
/// present, no `id`) before decoding a fully typed payload.
struct JSONRPCEnvelopePeek: Decodable {
    let id: Int?
    let method: String?
}

/// An empty JSON object (`{}`), used for payloads that carry no data on the
/// wire — `initialized`, `shutdown`, `exit`, and `initialize`'s
/// `capabilities` (plan.md: "no capability gating, empty/null results mean
/// 'no data'").
struct EmptyPayload: Codable {}

// MARK: - initialize / initialized / shutdown / exit

/// Params for the `initialize` request.
struct InitializeParams: Encodable {
    let processID: Int?
    let rootURI: DocumentURI?
    let capabilities = EmptyPayload()

    private enum CodingKeys: String, CodingKey {
        case processID = "processId"
        case rootURI = "rootUri"
        case capabilities
    }
}

/// The result of the `initialize` request.
///
/// Deliberately empty: this package never gates behavior on server
/// capabilities (plan.md: "no capability gating"), so every field a real
/// server sends back is simply ignored rather than modeled.
struct InitializeResult: Decodable {}

// MARK: - textDocument/didOpen, didChange, didSave, didClose

/// Identifies a text document by URI alone.
struct TextDocumentIdentifier: Codable {
    let uri: DocumentURI
}

/// Identifies a text document by URI at a specific version.
struct VersionedTextDocumentIdentifier: Encodable {
    let uri: DocumentURI
    let version: Int
}

/// The full content of a text document as sent on `didOpen`.
struct TextDocumentItem: Encodable {
    let uri: DocumentURI
    let languageID: String
    let version: Int
    let text: String

    private enum CodingKeys: String, CodingKey {
        case uri
        case languageID = "languageId"
        case version
        case text
    }
}

/// Params for `textDocument/didOpen`.
struct DidOpenTextDocumentParams: Encodable {
    let textDocument: TextDocumentItem
}

/// A full-document content replacement, per the whole-document sync this
/// package uses (see `swissarmyhammer-lsp`'s `session.rs::change`, which
/// always sends `[{ "text": text }]` with no `range`).
struct TextDocumentContentChangeEvent: Encodable {
    let text: String
}

/// Params for `textDocument/didChange`, using full-document sync.
struct DidChangeTextDocumentParams: Encodable {
    let textDocument: VersionedTextDocumentIdentifier
    let contentChanges: [TextDocumentContentChangeEvent]
}

/// Params for `textDocument/didSave`.
///
/// No `text` field: this package never sends the saved content along with
/// `didSave`, mirroring `swissarmyhammer-lsp`'s `session.rs::save`.
struct DidSaveTextDocumentParams: Encodable {
    let textDocument: TextDocumentIdentifier
}

/// Params for `textDocument/didClose`.
struct DidCloseTextDocumentParams: Encodable {
    let textDocument: TextDocumentIdentifier
}

// MARK: - textDocument/documentSymbol

/// Params for `textDocument/documentSymbol`.
struct DocumentSymbolParams: Encodable {
    let textDocument: TextDocumentIdentifier
}

/// One entry of the modern, hierarchical `textDocument/documentSymbol`
/// result shape.
struct DocumentSymbol: Decodable {
    let name: String
    let detail: String?
    let kind: SymbolKind
    let range: LSPRange
    let selectionRange: LSPRange
    let children: [DocumentSymbol]?
}

/// One entry of the legacy, flat `textDocument/documentSymbol` result
/// shape, also reused for `workspace/symbol` results.
struct SymbolInformation: Decodable {
    let name: String
    let kind: SymbolKind
    let location: Location
    let containerName: String?
}

/// The result of `textDocument/documentSymbol`: either shape the server may
/// return, normalized to `[DocumentSymbol]` via `symbols`.
///
/// Ports `swissarmyhammer-lsp`'s `client.rs::parse_document_symbols`: a
/// flat `SymbolInformation` becomes a childless `DocumentSymbol` whose
/// `range` and `selectionRange` both equal `location.range`, and whose
/// `detail` is the original `containerName`.
enum DocumentSymbolResult: Decodable {
    case nested([DocumentSymbol])
    case flat([SymbolInformation])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            // The server found no symbols in the document; a legal LSP
            // `documentSymbol` result, matching `LocationsResult` and
            // `PrepareRenameResult`'s null handling elsewhere in this file.
            self = .nested([])
            return
        }
        if let nested = try? container.decode([DocumentSymbol].self) {
            self = .nested(nested)
            return
        }
        self = .flat(try container.decode([SymbolInformation].self))
    }

    /// Normalizes either wire shape to a flat `[DocumentSymbol]` list.
    var symbols: [DocumentSymbol] {
        switch self {
        case .nested(let symbols):
            return symbols
        case .flat(let infos):
            return infos.map { info in
                DocumentSymbol(
                    name: info.name,
                    detail: info.containerName,
                    kind: info.kind,
                    range: info.location.range,
                    selectionRange: info.location.range,
                    children: nil
                )
            }
        }
    }
}

// MARK: - definition / typeDefinition / references / implementation

/// Params shared by `textDocument/definition`, `typeDefinition`, `hover`,
/// `implementation`, `prepareCallHierarchy`, and `prepareRename`: a
/// document plus a cursor position.
struct TextDocumentPositionParams: Encodable {
    let textDocument: TextDocumentIdentifier
    let position: Position
}

/// The `context` object for `textDocument/references`.
struct ReferenceContext: Encodable {
    let includeDeclaration: Bool
}

/// Params for `textDocument/references`.
struct ReferenceParams: Encodable {
    let textDocument: TextDocumentIdentifier
    let position: Position
    let context: ReferenceContext
}

/// The result of `definition`/`typeDefinition`/`references`/`implementation`:
/// a single `Location`, an array of them, or `null`, normalized to
/// `locations`.
///
/// The `LocationLink[]` variant some servers can return instead of
/// `Location[]` is not modeled: this package never requests the capability
/// (`textDocument.definition.linkSupport`) that would trigger it.
struct LocationsResult: Decodable {
    let locations: [Location]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            locations = []
            return
        }
        if let array = try? container.decode([Location].self) {
            locations = array
            return
        }
        locations = [try container.decode(Location.self)]
    }
}

// MARK: - hover

/// A `{ "kind": "markdown" | "plaintext", "value": "..." }` hover contents
/// object.
private struct MarkupContent: Decodable {
    let value: String
}

/// One entry of the legacy `MarkedString | MarkedString[]` hover contents
/// shape: either a bare string or a `{ "language": ..., "value": "..." }`
/// object.
private struct MarkedStringItem: Decodable {
    let value: String

    private enum CodingKeys: String, CodingKey {
        case value
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), let plain = try? container.decode(String.self) {
            value = plain
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        value = try keyed.decode(String.self, forKey: .value)
    }
}

/// The result of `textDocument/hover`.
///
/// `contents` may arrive as a `MarkupContent` object, a plain string, or a
/// `MarkedString[]` array; all three are flattened to a single `String`
/// (array entries joined with `"\n"`), since this package only ever
/// displays hover text and never needs the structured markup distinction.
struct Hover: Decodable {
    let contents: String
    let range: LSPRange?

    private enum CodingKeys: String, CodingKey {
        case contents
        case range
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        range = try container.decodeIfPresent(LSPRange.self, forKey: .range)

        if let markup = try? container.decode(MarkupContent.self, forKey: .contents) {
            contents = markup.value
            return
        }
        if let plain = try? container.decode(String.self, forKey: .contents) {
            contents = plain
            return
        }
        let items = try container.decode([MarkedStringItem].self, forKey: .contents)
        contents = items.map(\.value).joined(separator: "\n")
    }
}

// MARK: - prepareCallHierarchy / callHierarchy/incomingCalls / outgoingCalls

/// Params for `callHierarchy/incomingCalls` and `callHierarchy/outgoingCalls`,
/// carrying back the exact `CallHierarchyItem` a `prepareCallHierarchy`
/// call returned.
struct CallHierarchyCallsParams: Encodable {
    let item: CallHierarchyItem
}

/// One entry of the `callHierarchy/incomingCalls` result: a caller plus the
/// ranges within it that call the target.
struct CallHierarchyIncomingCall: Decodable {
    let from: CallHierarchyItem
    let fromRanges: [LSPRange]
}

/// One entry of the `callHierarchy/outgoingCalls` result: a callee plus the
/// ranges within the target that call it.
struct CallHierarchyOutgoingCall: Decodable {
    let to: CallHierarchyItem
    let fromRanges: [LSPRange]
}

// MARK: - prepareRename / rename

/// The result of `textDocument/prepareRename`.
///
/// The server may respond with a plain `Range`, a `{ range, placeholder }`
/// object, a `{ defaultBehavior: true }` object, or `null`. The
/// `defaultBehavior` shape carries no usable range for this package's
/// purposes and normalizes to `range == nil`, same as `null`.
struct PrepareRenameResult: Decodable {
    let range: LSPRange?
    let placeholder: String?

    private struct RangeWithPlaceholder: Decodable {
        let range: LSPRange
        let placeholder: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            range = nil
            placeholder = nil
            return
        }
        if let withPlaceholder = try? container.decode(RangeWithPlaceholder.self) {
            range = withPlaceholder.range
            placeholder = withPlaceholder.placeholder
            return
        }
        if let plainRange = try? container.decode(LSPRange.self) {
            range = plainRange
            placeholder = nil
            return
        }
        // `{ "defaultBehavior": true }` or another shape we don't model.
        range = nil
        placeholder = nil
    }
}

/// Params for `textDocument/rename`.
struct RenameParams: Encodable {
    let textDocument: TextDocumentIdentifier
    let position: Position
    let newName: String
}

/// A single text replacement within a document.
struct TextEdit: Codable {
    let range: LSPRange
    let newText: String
}

/// The result of `textDocument/rename`: a workspace edit keyed by document
/// URI string.
struct WorkspaceEdit: Codable {
    let changes: [String: [TextEdit]]?
}

// MARK: - codeAction / codeAction/resolve

/// A minimal, order-preserving JSON value.
///
/// Used to round-trip the LSP `LSPAny`-typed fields this package never
/// interprets — `CodeAction.data` and `Command.arguments` — losslessly
/// between `codeAction` and `codeAction/resolve`, without modeling every
/// server's custom payload shape.
indirect enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unrecognized JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// The `context` object for `textDocument/codeAction`.
struct CodeActionContext: Encodable {
    let diagnostics: [Diagnostic]
    let only: [String]?
}

/// Params for `textDocument/codeAction`.
struct CodeActionParams: Encodable {
    let textDocument: TextDocumentIdentifier
    let range: LSPRange
    let context: CodeActionContext
}

/// The `command` object embedded in a `CodeAction`, or a bare `Command`
/// result item (the `(Command | CodeAction)[]` union this package doesn't
/// otherwise model, since every server it targets returns `CodeAction`).
struct CodeActionCommand: Codable {
    let title: String
    let command: String
    let arguments: [JSONValue]?
}

/// One entry of the `textDocument/codeAction` result, also the shape sent
/// back verbatim (with its `data` field intact) as `codeAction/resolve`'s
/// params.
struct CodeActionItem: Codable {
    let title: String
    let kind: String?
    let diagnostics: [Diagnostic]?
    let isPreferred: Bool?
    let edit: WorkspaceEdit?
    let command: CodeActionCommand?
    let data: JSONValue?
}

// MARK: - workspace/symbol

/// Params for `workspace/symbol`.
struct WorkspaceSymbolParams: Encodable {
    let query: String
}

// MARK: - textDocument/diagnostic (pull) / publishDiagnostics (push)

/// Params for `textDocument/diagnostic`.
struct DocumentDiagnosticParams: Encodable {
    let textDocument: TextDocumentIdentifier
}

/// Lenient parsing of both the push (`publishDiagnostics` notification) and
/// pull (`textDocument/diagnostic` request) diagnostics wire shapes.
///
/// Ports `swissarmyhammer-lsp`'s `diagnostics.rs`: a malformed individual
/// diagnostic item is skipped rather than failing the whole batch, matching
/// how editors tolerate partial server output. See `Diagnostic.init(from:)`
/// in `LSPTypes.swift` for the per-item leniency rules (missing
/// `range`/`message` skips the item; missing/unrecognized `severity`
/// defaults to `.hint`; a wrong-typed `code`/`source` is dropped without
/// skipping the item).
enum DiagnosticsParsing {
    /// One raw diagnostic item that decodes to `nil` (rather than throwing
    /// and aborting the whole array) when malformed, so
    /// `[FailableDiagnostic]` decoding is lenient per-element.
    private struct FailableDiagnostic: Decodable {
        let diagnostic: Diagnostic?

        init(from decoder: Decoder) throws {
            diagnostic = try? Diagnostic(from: decoder)
        }
    }

    /// The params object of a `textDocument/publishDiagnostics` notification:
    /// `{ "uri": "...", "diagnostics": [...] }`.
    private struct PublishDiagnosticsParams: Decodable {
        let diagnostics: [FailableDiagnostic]
    }

    /// Parses a `textDocument/publishDiagnostics` notification's params.
    ///
    /// Returns an empty array if `params` doesn't decode or lacks a
    /// `diagnostics` array.
    static func parsePublishDiagnostics(from params: Data) -> [Diagnostic] {
        guard let decoded = try? JSONDecoder().decode(PublishDiagnosticsParams.self, from: params) else {
            return []
        }
        return decoded.diagnostics.compactMap(\.diagnostic)
    }

    /// The `{ "items": [...] }` shape of a `textDocument/diagnostic` pull
    /// result (both the simplified and full `DocumentDiagnosticReport`
    /// shapes carry an `items` array).
    private struct ItemsWrapper: Decodable {
        let items: [FailableDiagnostic]
    }

    /// Parses a `textDocument/diagnostic` (pull) response result.
    ///
    /// Accepts `{ "items": [...] }` (simplified or full report) or a bare
    /// diagnostics array; any other shape (including `null`) yields an
    /// empty array.
    static func parseDiagnosticsFromResult(from result: Data) -> [Diagnostic] {
        if let wrapped = try? JSONDecoder().decode(ItemsWrapper.self, from: result) {
            return wrapped.items.compactMap(\.diagnostic)
        }
        if let bareArray = try? JSONDecoder().decode([FailableDiagnostic].self, from: result) {
            return bareArray.compactMap(\.diagnostic)
        }
        return []
    }
}
