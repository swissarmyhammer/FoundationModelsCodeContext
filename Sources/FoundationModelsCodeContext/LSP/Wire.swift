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
/// `LanguageServerConnection` protocol returns them directly. `JSONValue`
/// below is also public, because `ServerSpec.initializationOptions` holds one.
///
/// The `Content-Length` framing itself (`JSONRPCFraming.frame(payload:)` and
/// `JSONRPCMessageDecoder`) is in `Framing.swift`, which the scripted test server shares.
extension JSONRPCFraming {
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
    /// payload, to route it to a pending request (has `id`, no `method`), to
    /// the reply of a server request (has `id` and `method`) or to a
    /// server-initiated notification (has `method`, no `id`). See
    /// `JSONRPCEnvelopePeek.route`.
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

/// Gives each `WireError` a description that holds its associated values.
///
/// Without this conformance, `localizedDescription` gives only the case
/// index ("WireError error 1"), and a log line does not show the code and
/// the message that the server sent.
extension WireError: LocalizedError {
    /// The text that `localizedDescription` gives for this error.
    var errorDescription: String? {
        switch self {
        case .idMismatch(let expected, let actual):
            let actualText = actual.map(String.init) ?? "none"
            return "response id mismatch: expected \(expected), got \(actualText)"
        case .serverError(let code, let message):
            return "server error \(code): \(message)"
        case .missingResult:
            return "response has neither a result nor an error"
        }
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
        id = try container.decodeIfPresent(JSONRPCID.self, forKey: .id)?.requestNumber
        error = try container.decodeIfPresent(JSONRPCErrorPayload.self, forKey: .error)
        if container.contains(.result) {
            result = try container.decode(Result.self, forKey: .result)
        } else {
            result = nil
        }
    }
}

/// The `error` object of a JSON-RPC 2.0 error response. The client decodes it
/// in a response of the server, and encodes it in an error reply to a server
/// request.
struct JSONRPCErrorPayload: Codable {
    let code: Int
    let message: String
}

/// The `id` of a JSON-RPC 2.0 message. The specification permits a number or
/// a string.
///
/// The client sends only number ids (see `JSONRPCRequestEnvelope`), but a
/// server can send a string id: in its own requests to the client, and in a
/// response. A reply to a server request must hold the same id in the same
/// form, thus this type keeps the form and encodes it back without a change.
enum JSONRPCID: Codable, Sendable, Equatable, CustomStringConvertible,
    ExpressibleByIntegerLiteral, ExpressibleByStringLiteral
{
    /// A number id, such as `5`.
    case number(Int)

    /// A string id, such as `"5"` or `"progress-1"`.
    case string(String)

    /// Makes a number id from an integer literal.
    init(integerLiteral value: Int) {
        self = .number(value)
    }

    /// Makes a string id from a string literal.
    init(stringLiteral value: String) {
        self = .string(value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        }
    }

    /// The number of the client request that this id can answer: the number
    /// of a number id, or the decimal number that a string id holds (some
    /// servers send the id `"5"` in the response to the request `5`). `nil`
    /// for a string id that holds no decimal number: no client request has
    /// such an id.
    var requestNumber: Int? {
        switch self {
        case .number(let number): number
        case .string(let text): Int(text)
        }
    }

    /// The id as the log records show it: the number, or the string.
    var description: String {
        switch self {
        case .number(let number): String(number)
        case .string(let text): text
        }
    }
}

/// Where the reader loop sends one message from the server.
enum JSONRPCRoute: Equatable {
    /// A response to the pending client request with this number id.
    case response(id: Int)

    /// A request from the server to the client. The client must reply to it
    /// with the same `id`.
    case serverRequest(id: JSONRPCID, method: String)

    /// A notification from the server. It gets no reply.
    case notification(method: String)

    /// A message that no part of the client can use: a response whose id
    /// matches no client request, or a message with no `id` and no `method`.
    case unroutable
}

/// A minimal, untyped peek at a raw JSON-RPC message: enough to tell a
/// response, a server request and a server notification apart (see `route`)
/// before decoding a fully typed payload.
struct JSONRPCEnvelopePeek: Decodable {
    let id: JSONRPCID?
    let method: String?

    /// Where the message goes. A message with an `id` and a `method` is a
    /// server request, never a response: a response has no `method`. Thus a
    /// server request with the id of a pending client request never resolves
    /// that client request.
    var route: JSONRPCRoute {
        switch (id, method) {
        case (let id?, let method?):
            .serverRequest(id: id, method: method)
        case (let id?, nil):
            id.requestNumber.map { .response(id: $0) } ?? .unroutable
        case (nil, let method?):
            .notification(method: method)
        case (nil, nil):
            .unroutable
        }
    }
}

/// An empty JSON object (`{}`), used for payloads that carry no data on the
/// wire — `initialized`, `shutdown` and `exit`.
struct EmptyPayload: Codable {}

// MARK: - initialize / initialized / shutdown / exit

/// Params for the `initialize` request.
///
/// The synthesized encoder omits each `nil` optional, thus a spec with no
/// options sends no `initializationOptions` field, and a handshake with no
/// root sends no `workspaceFolders` field.
struct InitializeParams: Encodable {
    let processID: Int?
    let rootURI: DocumentURI?

    /// The server-specific options of `ServerSpec.initializationOptions`.
    let initializationOptions: JSONValue?

    /// The features that the client handles. See `ClientCapabilities`.
    let capabilities = ClientCapabilities()

    /// The one workspace folder of the handshake: the root. `nil` when there is no root.
    let workspaceFolders: [WorkspaceFolder]?

    private enum CodingKeys: String, CodingKey {
        case processID = "processId"
        case rootURI = "rootUri"
        case initializationOptions
        case capabilities
        case workspaceFolders
    }

    /// Creates the params of an `initialize` request.
    /// - Parameters:
    ///   - processID: The process id of the client, or `nil`.
    ///   - rootURI: The workspace root, or `nil`. It is also the one workspace folder.
    ///   - initializationOptions: The server-specific options. Defaults to `nil`: the request
    ///     then has no `initializationOptions` field.
    init(processID: Int?, rootURI: DocumentURI?, initializationOptions: JSONValue? = nil) {
        self.processID = processID
        self.rootURI = rootURI
        self.initializationOptions = initializationOptions
        self.workspaceFolders = rootURI.map { [WorkspaceFolder(uri: $0)] }
    }
}

/// One entry of the `workspaceFolders` of `initialize`.
struct WorkspaceFolder: Encodable {
    /// The URI of the folder.
    let uri: DocumentURI

    /// The name of the folder: the last path component of `uri`, or the full URI text when
    /// the URI has no path component.
    let name: String

    /// Creates the folder at `uri`, named after its last path component.
    /// - Parameter uri: The URI of the folder.
    init(uri: DocumentURI) {
        self.uri = uri
        let lastComponent = URL(string: uri.value)?.lastPathComponent ?? ""
        self.name = lastComponent.isEmpty || lastComponent == "/" ? uri.value : lastComponent
    }
}

/// The client capabilities of `initialize`: the features that this client handles.
///
/// The client declares only what it handles. It answers `client/registerCapability` but does
/// not use the registration, thus each feature declares `dynamicRegistration: false` and the
/// server must advertise the feature in its `initialize` result. It answers
/// `workspace/configuration` and `window/workDoneProgress/create` (see `ServerRequestReply`),
/// thus it declares `workspace.configuration` and `window.workDoneProgress`.
struct ClientCapabilities: Encodable {
    let textDocument = TextDocumentClientCapabilities()
    let workspace = WorkspaceClientCapabilities()
    let window = WindowClientCapabilities()
}

/// The `textDocument` part of `ClientCapabilities`: one entry for each `textDocument`
/// feature that `ProcessLanguageServerConnection` sends or receives.
struct TextDocumentClientCapabilities: Encodable {
    let synchronization = SynchronizationCapability()
    let publishDiagnostics = StaticRegistrationCapability()
    let diagnostic = StaticRegistrationCapability()
    let documentSymbol = DocumentSymbolCapability()
    let callHierarchy = StaticRegistrationCapability()
    let references = StaticRegistrationCapability()
    let definition = StaticRegistrationCapability()
    let hover = HoverCapability()
    let rename = RenameCapability()
    let codeAction = CodeActionCapability()
}

/// A feature capability with no other field than `dynamicRegistration: false`.
struct StaticRegistrationCapability: Encodable {
    let dynamicRegistration = false
}

/// The `textDocument.synchronization` capability: the client sends `didOpen`, `didChange`,
/// `didClose` and `didSave`.
struct SynchronizationCapability: Encodable {
    let dynamicRegistration = false
    let didSave = true
}

/// The `textDocument.documentSymbol` capability: the client decodes the hierarchical
/// `DocumentSymbol` shape.
struct DocumentSymbolCapability: Encodable {
    let dynamicRegistration = false
    let hierarchicalDocumentSymbolSupport = true
}

/// The `textDocument.hover` capability: `Hover` decodes markdown and plain text.
struct HoverCapability: Encodable {
    let dynamicRegistration = false
    let contentFormat = ["markdown", "plaintext"]
}

/// The `textDocument.rename` capability: the client sends `prepareRename` before `rename`.
struct RenameCapability: Encodable {
    let dynamicRegistration = false
    let prepareSupport = true
}

/// The `textDocument.codeAction` capability: the client decodes `CodeAction` objects, keeps
/// their `data` and sends `codeAction/resolve` to get their `edit`.
struct CodeActionCapability: Encodable {
    let dynamicRegistration = false
    let codeActionLiteralSupport = CodeActionLiteralSupport()
    let dataSupport = true
    let resolveSupport = CodeActionResolveSupport()
}

/// The `codeActionLiteralSupport` of `CodeActionCapability`: the code action kinds of LSP 3.17.
struct CodeActionLiteralSupport: Encodable {
    /// The `codeActionKind` object of the capability.
    struct Kinds: Encodable {
        let valueSet = [
            "", "quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite",
            "source", "source.organizeImports", "source.fixAll",
        ]
    }

    let codeActionKind = Kinds()
}

/// The `resolveSupport` of `CodeActionCapability`: `codeAction/resolve` fills in the `edit`.
struct CodeActionResolveSupport: Encodable {
    let properties = ["edit"]
}

/// The `workspace` part of `ClientCapabilities`.
struct WorkspaceClientCapabilities: Encodable {
    let workspaceFolders = true
    let configuration = true
}

/// The `window` part of `ClientCapabilities`.
struct WindowClientCapabilities: Encodable {
    let workDoneProgress = true
}

/// The result of the `initialize` request.
///
/// Keeps only the server capabilities that this package gates on (see
/// `ServerCapabilities` and plan.md "Capability gating"). Each other field
/// that a server sends is ignored. A result with no `capabilities` object
/// advertises no gated method.
struct InitializeResult: Decodable {
    /// The gated capabilities that the server advertises.
    let capabilities: ServerCapabilities

    private enum CodingKeys: String, CodingKey {
        case capabilities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let payload = try container.decodeIfPresent(ServerCapabilitiesPayload.self, forKey: .capabilities)
        capabilities = ServerCapabilities(
            callHierarchy: payload?.callHierarchyProvider?.isAdvertised ?? false,
            workspaceSymbol: payload?.workspaceSymbolProvider?.isAdvertised ?? false,
            implementation: payload?.implementationProvider?.isAdvertised ?? false
        )
    }
}

/// The gated provider fields of the `capabilities` object of an
/// `initialize` result. Each field that is absent is `nil`.
private struct ServerCapabilitiesPayload: Decodable {
    let callHierarchyProvider: ProviderOption?
    let workspaceSymbolProvider: ProviderOption?
    let implementationProvider: ProviderOption?
}

/// One `...Provider` field of a server capabilities object.
///
/// LSP lets a server write a provider as `true`, `false` or an options
/// object. `true` and an options object advertise the method; `false` and
/// `null` do not.
private struct ProviderOption: Decodable {
    /// Whether this field advertises the method.
    let isAdvertised: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            isAdvertised = false
        } else if let flag = try? container.decode(Bool.self) {
            isAdvertised = flag
        } else {
            isAdvertised = true
        }
    }
}

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
public struct DocumentSymbol: Decodable, Sendable {
    let name: String
    let detail: String?
    let kind: SymbolKind
    let range: LSPRange
    let selectionRange: LSPRange
    let children: [DocumentSymbol]?
}

/// One entry of the legacy, flat `textDocument/documentSymbol` result
/// shape, also reused for `workspace/symbol` results.
public struct SymbolInformation: Decodable, Sendable {
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
public struct Hover: Decodable, Sendable {
    let contents: String
    let range: LSPRange?

    /// Creates a hover result directly, bypassing the union-type wire decoding below.
    ///
    /// Used by `FakeLanguageServerConnection` to script typed `hover` results
    /// without ever constructing JSON: a custom `init(from:)` below (needed to
    /// decode the `MarkupContent | String | MarkedString[]` wire union)
    /// suppresses the compiler-synthesized memberwise initializer, so this
    /// one is provided explicitly.
    /// - Parameters:
    ///   - contents: The hover text, already flattened to a single string.
    ///   - range: The span the hover applies to, if any.
    init(contents: String, range: LSPRange?) {
        self.contents = contents
        self.range = range
    }

    private enum CodingKeys: String, CodingKey {
        case contents
        case range
    }

    public init(from decoder: Decoder) throws {
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
public struct CallHierarchyIncomingCall: Decodable, Sendable {
    let from: CallHierarchyItem
    let fromRanges: [LSPRange]
}

/// One entry of the `callHierarchy/outgoingCalls` result: a callee plus the
/// ranges within the target that call it.
public struct CallHierarchyOutgoingCall: Decodable, Sendable {
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
public struct PrepareRenameResult: Decodable, Sendable {
    let range: LSPRange?
    let placeholder: String?

    /// Creates a prepare-rename result directly, bypassing the union-type wire decoding below.
    ///
    /// Used by `FakeLanguageServerConnection` to script typed `prepareRename`
    /// results without ever constructing JSON: a custom `init(from:)` below
    /// (needed to decode the `Range | { range, placeholder } | { defaultBehavior }
    /// | null` wire union) suppresses the compiler-synthesized memberwise
    /// initializer, so this one is provided explicitly.
    /// - Parameters:
    ///   - range: The renameable span, or `nil` if the position can't be renamed.
    ///   - placeholder: The suggested placeholder text, if any.
    init(range: LSPRange?, placeholder: String?) {
        self.range = range
        self.placeholder = placeholder
    }

    private struct RangeWithPlaceholder: Decodable {
        let range: LSPRange
        let placeholder: String
    }

    public init(from decoder: Decoder) throws {
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
struct TextEdit: Codable, Equatable {
    let range: LSPRange
    let newText: String
}

/// The result of `textDocument/rename`: a workspace edit keyed by document
/// URI string.
public struct WorkspaceEdit: Codable, Equatable, Sendable {
    let changes: [String: [TextEdit]]?
}

// MARK: - codeAction / codeAction/resolve

/// A minimal, order-preserving JSON value.
///
/// Used to round-trip the LSP `LSPAny`-typed fields this package never
/// interprets — `CodeAction.data` and `Command.arguments` — losslessly
/// between `codeAction` and `codeAction/resolve`, without modeling every
/// server's custom payload shape.
///
/// Public because `ServerSpec.initializationOptions` holds one: a language
/// module gives the server-specific options of `initialize` as a `JSONValue`.
public indirect enum JSONValue: Codable, Sendable, Equatable {
    /// A JSON string.
    case string(String)

    /// A JSON number.
    case number(Double)

    /// A JSON `true` or `false`.
    case bool(Bool)

    /// A JSON object.
    case object([String: JSONValue])

    /// A JSON array.
    case array([JSONValue])

    /// The JSON `null`.
    case null

    /// Decodes any JSON value.
    /// - Parameter decoder: The decoder to read the value from.
    /// - Throws: `DecodingError.dataCorrupted` when the value is not JSON.
    public init(from decoder: Decoder) throws {
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

    /// Encodes the JSON value.
    /// - Parameter encoder: The encoder to write the value to.
    /// - Throws: Whatever the single-value container throws.
    public func encode(to encoder: Encoder) throws {
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
struct CodeActionCommand: Codable, Equatable {
    let title: String
    let command: String
    let arguments: [JSONValue]?
}

/// One entry of the `textDocument/codeAction` result, also the shape sent
/// back verbatim (with its `data` field intact) as `codeAction/resolve`'s
/// params.
public struct CodeActionItem: Codable, Equatable, Sendable {
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
