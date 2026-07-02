import Foundation
import Testing

@testable import CodeContextKit

/// Framing, envelope, and payload-decoding tests for the private LSP wire
/// codec (`Sources/CodeContextKit/LSP/Wire.swift` + `LSPTypes.swift`).
///
/// Fixtures are trimmed real transcripts from `rust-analyzer` and
/// `sourcekit-lsp`, matching the LSP 3.17 specification shapes for the
/// methods this package uses. See plan.md "LSP subsystem" for the
/// private-wire-codec design this ports from `swissarmyhammer-lsp`.
struct WireTests {
    // MARK: - Content-Length framing

    @Test
    func frameProducesContentLengthHeaderFollowedByBody() {
        let payload = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)
        let framed = JSONRPCFraming.frame(payload: payload)
        let framedString = String(decoding: framed, as: UTF8.self)

        #expect(framedString == "Content-Length: \(payload.count)\r\n\r\n" + String(decoding: payload, as: UTF8.self))
    }

    @Test
    func decoderRoundTripsASingleMessage() {
        let payload = Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8)
        let framed = JSONRPCFraming.frame(payload: payload)

        var decoder = JSONRPCMessageDecoder()
        let messages = decoder.append(bytes: framed)

        #expect(messages == [payload])
    }

    @Test
    func decoderRoundTripsMultiByteUTF8Payload() {
        // "こんにちは" (Japanese greeting) and an emoji: several bytes per
        // scalar, so a byte-count Content-Length must be used, not a
        // character count.
        let payload = Data(#"{"jsonrpc":"2.0","id":1,"result":{"message":"こんにちは 👋"}}"#.utf8)
        let framed = JSONRPCFraming.frame(payload: payload)

        var decoder = JSONRPCMessageDecoder()
        let messages = decoder.append(bytes: framed)

        #expect(messages == [payload])
    }

    @Test
    func decoderHandlesSplitReadsAcrossTheHeaderBoundary() {
        let payload = Data(#"{"jsonrpc":"2.0","id":2,"method":"textDocument/didOpen"}"#.utf8)
        let framed = JSONRPCFraming.frame(payload: payload)

        var decoder = JSONRPCMessageDecoder()
        var messages: [Data] = []
        // Feed one byte at a time to exercise the worst-case chunking,
        // including a split in the middle of "Content-Length:".
        for byte in framed {
            messages.append(contentsOf: decoder.append(bytes: Data([byte])))
        }

        #expect(messages == [payload])
    }

    @Test
    func decoderHandlesSplitReadsAcrossTheBodyBoundary() {
        let payload = Data(#"{"jsonrpc":"2.0","id":3,"result":{"ok":true}}"#.utf8)
        let framed = JSONRPCFraming.frame(payload: payload)
        let splitPoint = framed.count - 5

        var decoder = JSONRPCMessageDecoder()
        var messages: [Data] = []
        messages.append(contentsOf: decoder.append(bytes: framed.prefix(splitPoint)))
        #expect(messages.isEmpty, "must not yield a message before the full body has arrived")
        messages.append(contentsOf: decoder.append(bytes: framed.suffix(from: splitPoint)))

        #expect(messages == [payload])
    }

    @Test
    func decoderYieldsMultipleMessagesFromOneChunk() {
        let first = Data(#"{"jsonrpc":"2.0","id":1,"result":1}"#.utf8)
        let second = Data(#"{"jsonrpc":"2.0","id":2,"result":2}"#.utf8)
        var combined = JSONRPCFraming.frame(payload: first)
        combined.append(JSONRPCFraming.frame(payload: second))

        var decoder = JSONRPCMessageDecoder()
        let messages = decoder.append(bytes: combined)

        #expect(messages == [first, second])
    }

    @Test
    func decoderIgnoresUnknownHeadersBeforeContentLength() {
        let payload = Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8)
        var framed = Data("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n".utf8)
        framed.append(Data("Content-Length: \(payload.count)\r\n\r\n".utf8))
        framed.append(payload)

        var decoder = JSONRPCMessageDecoder()
        let messages = decoder.append(bytes: framed)

        #expect(messages == [payload])
    }

    // MARK: - JSON-RPC envelopes and id matching

    @Test
    func requestEnvelopeEncodesJsonrpcIdMethodAndParams() throws {
        struct Params: Encodable { let uri: String }
        let request = JSONRPCRequestEnvelope(id: 7, method: "textDocument/hover", params: Params(uri: "file:///a.swift"))
        let data = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? Int == 7)
        #expect(object["method"] as? String == "textDocument/hover")
        let params = try #require(object["params"] as? [String: Any])
        #expect(params["uri"] as? String == "file:///a.swift")
    }

    @Test
    func notificationEnvelopeOmitsId() throws {
        struct Params: Encodable { let text: String }
        let notification = JSONRPCNotificationEnvelope(method: "textDocument/didSave", params: Params(text: "hi"))
        let data = try JSONEncoder().encode(notification)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["id"] == nil)
        #expect(object["method"] as? String == "textDocument/didSave")
    }

    @Test
    func decodeResultExtractsMatchingResponseById() throws {
        let raw = Data(#"{"jsonrpc":"2.0","id":42,"result":{"value":"ok"}}"#.utf8)
        struct Result: Decodable, Equatable { let value: String }

        let decoded = try JSONRPCFraming.decodeResult(as: Result.self, from: raw, expectedID: 42)
        #expect(decoded == Result(value: "ok"))
    }

    @Test
    func decodeResultThrowsOnIdMismatch() {
        let raw = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        struct Result: Decodable {}

        #expect(throws: (any Error).self) {
            try JSONRPCFraming.decodeResult(as: Result.self, from: raw, expectedID: 99)
        }
    }

    @Test
    func decodeResultThrowsOnServerError() {
        let raw = Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found"}}"#.utf8)
        struct Result: Decodable {}

        #expect(throws: (any Error).self) {
            try JSONRPCFraming.decodeResult(as: Result.self, from: raw, expectedID: 1)
        }
    }

    @Test
    func decodeResultTreatsNullResultAsNilForOptionalPayloads() throws {
        let raw = Data(#"{"jsonrpc":"2.0","id":5,"result":null}"#.utf8)
        struct Result: Decodable, Equatable { let value: String }

        let decoded = try JSONRPCFraming.decodeResult(as: Result?.self, from: raw, expectedID: 5)
        #expect(decoded == nil)
    }

    @Test
    func peekNotificationExtractsMethodFromServerPush() throws {
        let raw = Data(#"{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///a.rs","diagnostics":[]}}"#.utf8)
        let peek = try JSONRPCFraming.peek(message: raw)

        #expect(peek.id == nil)
        #expect(peek.method == "textDocument/publishDiagnostics")
    }

    @Test
    func peekResponseExtractsId() throws {
        let raw = Data(#"{"jsonrpc":"2.0","id":9,"result":null}"#.utf8)
        let peek = try JSONRPCFraming.peek(message: raw)

        #expect(peek.id == 9)
        #expect(peek.method == nil)
    }

    // MARK: - initialize / initialized / shutdown / exit

    @Test
    func initializeParamsEncodesRootUriAndEmptyCapabilities() throws {
        let params = InitializeParams(processID: 1234, rootURI: DocumentURI("file:///repo"))
        let data = try JSONEncoder().encode(params)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["processId"] as? Int == 1234)
        #expect(object["rootUri"] as? String == "file:///repo")
        #expect(object["capabilities"] as? [String: Any] != nil)
    }

    @Test
    func initializeResultIgnoresUnknownServerCapabilityFields() throws {
        // Real rust-analyzer initialize responses carry dozens of capability
        // fields we never read; the empty result type must decode any of them
        // without failing.
        let json = Data(
            #"""
            {
              "capabilities": {
                "textDocumentSync": 2,
                "hoverProvider": true,
                "documentSymbolProvider": {"label": "rust-analyzer"},
                "workspace": {"workspaceFolders": {"supported": true}}
              },
              "serverInfo": {"name": "rust-analyzer", "version": "0.3.2000"}
            }
            """#.utf8)
        _ = try JSONDecoder().decode(InitializeResult.self, from: json)
    }

    // MARK: - didOpen / didChange / didSave / didClose

    @Test
    func didOpenParamsMatchesFullDocumentSyncShape() throws {
        let params = DidOpenTextDocumentParams(
            textDocument: TextDocumentItem(uri: DocumentURI("file:///a.rs"), languageID: "rust", version: 1, text: "fn main() {}")
        )
        let data = try JSONEncoder().encode(params)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let textDocument = try #require(object["textDocument"] as? [String: Any])

        #expect(textDocument["uri"] as? String == "file:///a.rs")
        #expect(textDocument["languageId"] as? String == "rust")
        #expect(textDocument["version"] as? Int == 1)
        #expect(textDocument["text"] as? String == "fn main() {}")
    }

    @Test
    func didChangeParamsSendsFullTextReplacement() throws {
        let params = DidChangeTextDocumentParams(
            textDocument: VersionedTextDocumentIdentifier(uri: DocumentURI("file:///a.rs"), version: 2),
            contentChanges: [TextDocumentContentChangeEvent(text: "fn main() { println!(\"hi\"); }")]
        )
        let data = try JSONEncoder().encode(params)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let changes = try #require(object["contentChanges"] as? [[String: Any]])

        #expect(changes.count == 1)
        #expect(changes[0]["text"] as? String == "fn main() { println!(\"hi\"); }")
        #expect(changes[0]["range"] == nil, "full-document sync must not send a range")
    }

    @Test
    func didCloseParamsSendsOnlyTextDocumentIdentifier() throws {
        let params = DidCloseTextDocumentParams(textDocument: TextDocumentIdentifier(uri: DocumentURI("file:///a.rs")))
        let data = try JSONEncoder().encode(params)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object.count == 1)
        #expect((object["textDocument"] as? [String: Any])?["uri"] as? String == "file:///a.rs")
    }

    // MARK: - documentSymbol: nested DocumentSymbol[] shape

    @Test
    func documentSymbolResultDecodesNestedShape() throws {
        // Trimmed sourcekit-lsp transcript: nested DocumentSymbol[] with a
        // method inside a struct.
        let json = Data(
            #"""
            [
              {
                "name": "Store",
                "kind": 23,
                "range": {"start": {"line": 10, "character": 0}, "end": {"line": 40, "character": 1}},
                "selectionRange": {"start": {"line": 10, "character": 7}, "end": {"line": 10, "character": 12}},
                "children": [
                  {
                    "name": "markIndexed",
                    "kind": 6,
                    "range": {"start": {"line": 20, "character": 4}, "end": {"line": 25, "character": 5}},
                    "selectionRange": {"start": {"line": 20, "character": 9}, "end": {"line": 20, "character": 20}}
                  }
                ]
              }
            ]
            """#.utf8)

        let result = try JSONDecoder().decode(DocumentSymbolResult.self, from: json)
        let symbols = result.symbols

        #expect(symbols.count == 1)
        #expect(symbols[0].name == "Store")
        #expect(symbols[0].kind == .struct)
        #expect(symbols[0].children?.count == 1)
        #expect(symbols[0].children?[0].name == "markIndexed")
        #expect(symbols[0].children?[0].kind == .method)
    }

    // MARK: - documentSymbol: legacy flat SymbolInformation[] shape

    @Test
    func documentSymbolResultDecodesLegacyFlatShapeAndNormalizes() throws {
        // Trimmed rust-analyzer-style legacy SymbolInformation[] transcript.
        let json = Data(
            #"""
            [
              {
                "name": "parse_document_symbols",
                "kind": 12,
                "location": {
                  "uri": "file:///src/client.rs",
                  "range": {"start": {"line": 450, "character": 0}, "end": {"line": 482, "character": 1}}
                },
                "containerName": "client"
              }
            ]
            """#.utf8)

        let result = try JSONDecoder().decode(DocumentSymbolResult.self, from: json)
        let symbols = result.symbols

        #expect(symbols.count == 1)
        let symbol = symbols[0]
        #expect(symbol.name == "parse_document_symbols")
        #expect(symbol.kind == .function)
        #expect(symbol.detail == "client")
        #expect(symbol.children == nil)
        // Legacy conversion: range == selectionRange == location.range.
        #expect(symbol.range == symbol.selectionRange)
        #expect(symbol.range.start.line == 450)
        #expect(symbol.range.end.line == 482)
    }

    @Test
    func documentSymbolResultEmptyArrayDecodesToNoSymbols() throws {
        let result = try JSONDecoder().decode(DocumentSymbolResult.self, from: Data("[]".utf8))
        #expect(result.symbols.isEmpty)
    }

    @Test
    func documentSymbolResultNullDecodesToNoSymbols() throws {
        // A server may legally answer `textDocument/documentSymbol` with a
        // bare `null` result (no symbols), same as `LocationsResult` and
        // `PrepareRenameResult` handle `null` elsewhere in Wire.swift.
        let result = try JSONDecoder().decode(DocumentSymbolResult.self, from: Data("null".utf8))
        #expect(result.symbols.isEmpty)
    }

    // MARK: - definition / typeDefinition / references / implementation

    @Test
    func locationsResultDecodesSingleLocation() throws {
        let json = Data(
            #"""
            {"uri": "file:///src/main.rs", "range": {"start": {"line": 4, "character": 4}, "end": {"line": 4, "character": 10}}}
            """#.utf8)
        let result = try JSONDecoder().decode(LocationsResult.self, from: json)

        #expect(result.locations.count == 1)
        #expect(result.locations[0].uri.value == "file:///src/main.rs")
    }

    @Test
    func locationsResultDecodesLocationArray() throws {
        let json = Data(
            #"""
            [
              {"uri": "file:///a.rs", "range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 3}}},
              {"uri": "file:///b.rs", "range": {"start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 3}}}
            ]
            """#.utf8)
        let result = try JSONDecoder().decode(LocationsResult.self, from: json)

        #expect(result.locations.count == 2)
        #expect(result.locations[1].uri.value == "file:///b.rs")
    }

    @Test
    func locationsResultDecodesNullAsEmpty() throws {
        let result = try JSONDecoder().decode(LocationsResult.self, from: Data("null".utf8))
        #expect(result.locations.isEmpty)
    }

    // MARK: - hover

    @Test
    func hoverDecodesMarkupContentShape() throws {
        // Trimmed rust-analyzer hover transcript.
        let json = Data(
            #"""
            {
              "contents": {"kind": "markdown", "value": "```rust\nfn main()\n```"},
              "range": {"start": {"line": 0, "character": 3}, "end": {"line": 0, "character": 7}}
            }
            """#.utf8)
        let hover = try JSONDecoder().decode(Hover.self, from: json)

        #expect(hover.contents == "```rust\nfn main()\n```")
        #expect(hover.range?.start.character == 3)
    }

    @Test
    func hoverDecodesPlainStringContentsShape() throws {
        let json = Data(#"{"contents": "quick info"}"#.utf8)
        let hover = try JSONDecoder().decode(Hover.self, from: json)

        #expect(hover.contents == "quick info")
        #expect(hover.range == nil)
    }

    @Test
    func hoverDecodesMarkedStringArrayShape() throws {
        let json = Data(#"{"contents": ["first", {"language": "swift", "value": "second"}]}"#.utf8)
        let hover = try JSONDecoder().decode(Hover.self, from: json)

        #expect(hover.contents == "first\nsecond")
    }

    // MARK: - prepareCallHierarchy / incomingCalls / outgoingCalls

    @Test
    func callHierarchyItemDecodesAndRoundTrips() throws {
        let json = Data(
            #"""
            {
              "name": "parseDocumentSymbols",
              "kind": 12,
              "uri": "file:///src/wire.swift",
              "range": {"start": {"line": 10, "character": 0}, "end": {"line": 20, "character": 1}},
              "selectionRange": {"start": {"line": 10, "character": 9}, "end": {"line": 10, "character": 29}}
            }
            """#.utf8)
        let item = try JSONDecoder().decode(CallHierarchyItem.self, from: json)

        #expect(item.name == "parseDocumentSymbols")
        #expect(item.kind == .function)
        #expect(item.uri.value == "file:///src/wire.swift")

        // Round trip: encoding the decoded item must produce a payload the
        // server can accept back as `item` in incoming/outgoingCalls params.
        let reencoded = try JSONEncoder().encode(item)
        let redecoded = try JSONDecoder().decode(CallHierarchyItem.self, from: reencoded)
        #expect(redecoded == item)
    }

    @Test
    func incomingCallsResultDecodesFromAndFromRanges() throws {
        let json = Data(
            #"""
            [
              {
                "from": {
                  "name": "caller",
                  "kind": 12,
                  "uri": "file:///a.swift",
                  "range": {"start": {"line": 0, "character": 0}, "end": {"line": 5, "character": 1}},
                  "selectionRange": {"start": {"line": 0, "character": 5}, "end": {"line": 0, "character": 11}}
                },
                "fromRanges": [
                  {"start": {"line": 2, "character": 4}, "end": {"line": 2, "character": 10}}
                ]
              }
            ]
            """#.utf8)
        let calls = try JSONDecoder().decode([CallHierarchyIncomingCall].self, from: json)

        #expect(calls.count == 1)
        #expect(calls[0].from.name == "caller")
        #expect(calls[0].fromRanges.count == 1)
    }

    @Test
    func outgoingCallsResultDecodesToAndFromRanges() throws {
        let json = Data(
            #"""
            [
              {
                "to": {
                  "name": "callee",
                  "kind": 12,
                  "uri": "file:///b.swift",
                  "range": {"start": {"line": 0, "character": 0}, "end": {"line": 5, "character": 1}},
                  "selectionRange": {"start": {"line": 0, "character": 5}, "end": {"line": 0, "character": 11}}
                },
                "fromRanges": [
                  {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 6}}
                ]
              }
            ]
            """#.utf8)
        let calls = try JSONDecoder().decode([CallHierarchyOutgoingCall].self, from: json)

        #expect(calls.count == 1)
        #expect(calls[0].to.name == "callee")
    }

    // MARK: - prepareRename / rename

    @Test
    func prepareRenameDecodesPlainRangeShape() throws {
        let json = Data(#"{"start": {"line": 3, "character": 4}, "end": {"line": 3, "character": 9}}"#.utf8)
        let result = try JSONDecoder().decode(PrepareRenameResult.self, from: json)

        #expect(result.range?.start.character == 4)
        #expect(result.placeholder == nil)
    }

    @Test
    func prepareRenameDecodesRangeWithPlaceholderShape() throws {
        let json = Data(
            #"""
            {"range": {"start": {"line": 3, "character": 4}, "end": {"line": 3, "character": 9}}, "placeholder": "value"}
            """#.utf8)
        let result = try JSONDecoder().decode(PrepareRenameResult.self, from: json)

        #expect(result.placeholder == "value")
        #expect(result.range?.start.line == 3)
    }

    @Test
    func prepareRenameDecodesNullAsUnavailable() throws {
        let result = try JSONDecoder().decode(PrepareRenameResult.self, from: Data("null".utf8))
        #expect(result.range == nil)
        #expect(result.placeholder == nil)
    }

    @Test
    func renameParamsEncodesNewName() throws {
        let params = RenameParams(
            textDocument: TextDocumentIdentifier(uri: DocumentURI("file:///a.swift")),
            position: Position(line: 1, character: 2),
            newName: "renamed"
        )
        let data = try JSONEncoder().encode(params)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["newName"] as? String == "renamed")
    }

    @Test
    func workspaceEditDecodesChangesKeyedByUri() throws {
        let json = Data(
            #"""
            {
              "changes": {
                "file:///a.swift": [
                  {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 3}}, "newText": "let"}
                ]
              }
            }
            """#.utf8)
        let edit = try JSONDecoder().decode(WorkspaceEdit.self, from: json)

        let edits = try #require(edit.changes?["file:///a.swift"])
        #expect(edits.count == 1)
        #expect(edits[0].newText == "let")
    }

    // MARK: - codeAction / codeAction/resolve

    @Test
    func codeActionResultDecodesTitleKindAndEdit() throws {
        let json = Data(
            #"""
            [
              {
                "title": "Add missing import",
                "kind": "quickfix",
                "edit": {
                  "changes": {
                    "file:///a.swift": [
                      {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}}, "newText": "import Foundation\n"}
                    ]
                  }
                },
                "data": {"opaque": 1}
              }
            ]
            """#.utf8)
        let actions = try JSONDecoder().decode([CodeActionItem].self, from: json)

        #expect(actions.count == 1)
        #expect(actions[0].title == "Add missing import")
        #expect(actions[0].kind == "quickfix")
        #expect(actions[0].edit?.changes?["file:///a.swift"]?.count == 1)
    }

    @Test
    func codeActionResolveRoundTripsOpaqueDataField() throws {
        let json = Data(#"{"title": "Fix", "data": {"opaque": 1, "nested": [1, 2, 3]}}"#.utf8)
        let action = try JSONDecoder().decode(CodeActionItem.self, from: json)

        let reencoded = try JSONEncoder().encode(action)
        let redecoded = try JSONDecoder().decode(CodeActionItem.self, from: reencoded)

        #expect(redecoded.data == action.data)
    }

    // MARK: - workspace/symbol

    @Test
    func workspaceSymbolParamsEncodesQuery() throws {
        let params = WorkspaceSymbolParams(query: "Store")
        let data = try JSONEncoder().encode(params)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["query"] as? String == "Store")
    }

    @Test
    func workspaceSymbolResultDecodesSymbolInformationItems() throws {
        let json = Data(
            #"""
            [
              {
                "name": "Store",
                "kind": 23,
                "location": {
                  "uri": "file:///Sources/Index/Store.swift",
                  "range": {"start": {"line": 33, "character": 0}, "end": {"line": 33, "character": 5}}
                }
              }
            ]
            """#.utf8)
        let items = try JSONDecoder().decode([SymbolInformation].self, from: json)

        #expect(items.count == 1)
        #expect(items[0].name == "Store")
        #expect(items[0].kind == .struct)
    }

    // MARK: - Lenient diagnostics parsing (push + pull), per swissarmyhammer-lsp diagnostics.rs

    @Test
    func parsePublishDiagnosticsDecodesValidItems() {
        let params = Data(
            #"""
            {
              "uri": "file:///src/main.rs",
              "diagnostics": [
                {
                  "range": {"start": {"line": 5, "character": 10}, "end": {"line": 5, "character": 20}},
                  "severity": 1,
                  "message": "mismatched types",
                  "code": "E0308",
                  "source": "rustc"
                },
                {
                  "range": {"start": {"line": 12, "character": 0}, "end": {"line": 12, "character": 15}},
                  "severity": 2,
                  "message": "unused variable",
                  "source": "clippy"
                }
              ]
            }
            """#.utf8)

        let diagnostics = DiagnosticsParsing.parsePublishDiagnostics(from: params)

        #expect(diagnostics.count == 2)
        #expect(diagnostics[0].severity == .error)
        #expect(diagnostics[0].message == "mismatched types")
        #expect(diagnostics[0].code == "E0308")
        #expect(diagnostics[0].source == "rustc")
        #expect(diagnostics[1].severity == .warning)
    }

    @Test
    func parsePublishDiagnosticsMissingKeyYieldsEmpty() {
        let params = Data(#"{"uri": "file:///src/main.rs"}"#.utf8)
        #expect(DiagnosticsParsing.parsePublishDiagnostics(from: params).isEmpty)
    }

    @Test
    func parsePublishDiagnosticsSkipsMalformedItemsButKeepsValidOnes() {
        let params = Data(
            #"""
            {
              "uri": "file:///src/lib.rs",
              "diagnostics": [
                {"range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 10}}, "severity": 1, "message": "valid error"},
                {"message": "missing range - skipped"},
                {"range": {"start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 5}}, "severity": 3, "message": "valid info"}
              ]
            }
            """#.utf8)

        let diagnostics = DiagnosticsParsing.parsePublishDiagnostics(from: params)

        #expect(diagnostics.count == 2)
        #expect(diagnostics[0].message == "valid error")
        #expect(diagnostics[1].message == "valid info")
    }

    @Test
    func parseDiagnosticsFromResultHandlesFullReportShape() {
        let result = Data(
            #"""
            {
              "kind": "full",
              "items": [
                {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}}, "severity": 1, "message": "syntax error"}
              ]
            }
            """#.utf8)
        let diagnostics = DiagnosticsParsing.parseDiagnosticsFromResult(from: result)

        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].message == "syntax error")
    }

    @Test
    func parseDiagnosticsFromResultHandlesDirectArrayShape() {
        let result = Data(
            #"""
            [
              {"range": {"start": {"line": 3, "character": 4}, "end": {"line": 3, "character": 10}}, "severity": 2, "message": "deprecated function"}
            ]
            """#.utf8)
        let diagnostics = DiagnosticsParsing.parseDiagnosticsFromResult(from: result)

        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .warning)
    }

    @Test
    func parseDiagnosticsFromResultUnrecognizedShapeYieldsEmpty() {
        #expect(DiagnosticsParsing.parseDiagnosticsFromResult(from: Data("42".utf8)).isEmpty)
        #expect(DiagnosticsParsing.parseDiagnosticsFromResult(from: Data("null".utf8)).isEmpty)
        #expect(DiagnosticsParsing.parseDiagnosticsFromResult(from: Data("true".utf8)).isEmpty)
        #expect(DiagnosticsParsing.parseDiagnosticsFromResult(from: Data(#""not a diagnostic""#.utf8)).isEmpty)
    }

    @Test
    func diagnosticMissingSeverityDefaultsToHint() {
        let result = Data(
            #"""
            {"items": [
              {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}}, "message": "info message"}
            ]}
            """#.utf8)
        let diagnostics = DiagnosticsParsing.parseDiagnosticsFromResult(from: result)

        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].severity == .hint)
    }

    @Test
    func diagnosticUnknownSeverityNumberDefaultsToHint() {
        let result = Data(
            #"""
            {"items": [
              {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}}, "severity": 99, "message": "weird severity"}
            ]}
            """#.utf8)
        let diagnostics = DiagnosticsParsing.parseDiagnosticsFromResult(from: result)

        #expect(diagnostics[0].severity == .hint)
    }

    @Test
    func diagnosticNonStringNonNumberCodeIsDroppedButItemKept() {
        let result = Data(
            #"""
            {"items": [
              {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}}, "severity": 1, "message": "test", "code": true}
            ]}
            """#.utf8)
        let diagnostics = DiagnosticsParsing.parseDiagnosticsFromResult(from: result)

        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].code == nil)
    }

    @Test
    func diagnosticNumericCodeDecodesAsString() {
        let result = Data(
            #"""
            {"items": [
              {"range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 10}}, "severity": 1, "message": "error", "code": 42}
            ]}
            """#.utf8)
        let diagnostics = DiagnosticsParsing.parseDiagnosticsFromResult(from: result)

        #expect(diagnostics[0].code == "42")
    }

    @Test
    func diagnosticNonStringSourceIsDroppedButItemKept() {
        let result = Data(
            #"""
            {"items": [
              {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}}, "severity": 1, "message": "test", "source": 123}
            ]}
            """#.utf8)
        let diagnostics = DiagnosticsParsing.parseDiagnosticsFromResult(from: result)

        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].source == nil)
    }

    @Test
    func diagnosticIncompleteRangeSkipsItem() {
        let result = Data(
            #"""
            {"items": [
              {"range": {"start": {"line": 0}, "end": {"line": 0, "character": 5}}, "severity": 1, "message": "bad range"}
            ]}
            """#.utf8)
        #expect(DiagnosticsParsing.parseDiagnosticsFromResult(from: result).isEmpty)
    }
}
