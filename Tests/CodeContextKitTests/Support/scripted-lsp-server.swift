#!/usr/bin/env swift
//
// scripted-lsp-server.swift
//
// A tiny Content-Length-framed JSON-RPC stub, run as a standalone script
// (via `/usr/bin/env swift`, the same launch mechanism
// `ProcessLanguageServerConnection` uses for real language servers) so
// `ConnectionTests.swift` can drive the connection end-to-end against a real
// child process without depending on an actual language server being
// installed.
//
// Driven by a JSON "script" passed as argv[1]: an array of steps, executed
// in order.
//
//   {"action": "read"}
//     Reads one framed JSON-RPC message from stdin and remembers its `id`
//     and (if present) its `params.textDocument.uri` (appended to an
//     ordered list of "requests read so far").
//
//   {"action": "respond", "which": <Int>, "result": <any JSON>}
//     Writes a framed JSON-RPC response for the `which`-th request read so
//     far (0-based, in read order — not necessarily response order, so a
//     script can answer requests out of order).
//
//   {"action": "respond", "uri": <String>, "result": <any JSON>}
//     Writes a framed JSON-RPC response for whichever request read so far
//     had `params.textDocument.uri == uri`, whatever its JSON-RPC id turned
//     out to be. Use this instead of "which" whenever the physical order
//     two concurrent requests arrive on the wire isn't guaranteed by the
//     caller (e.g. two `async let` calls racing to be scheduled onto the
//     same actor) but a test still wants to assert out-of-order-response
//     handling deterministically, keyed by which logical request each
//     response answers rather than by read order.
//
//   {"action": "notify", "method": <String>, "params": <any JSON>}
//     Writes a framed JSON-RPC notification (no id), simulating a
//     server-initiated push such as `textDocument/publishDiagnostics`.
//
//   {"action": "hang"}
//     Blocks forever without exiting, so the process stays alive (and the
//     pipe doesn't hit EOF) while deliberately never answering a pending
//     request — used to drive `ConnectionTests`' timeout scenario.
//
// Deliberately does not import CodeContextKit: this runs as an independent
// process, not linked against the package under test.

import Foundation

let standardInput = FileHandle.standardInput
let standardOutput = FileHandle.standardOutput

/// Reads exactly one byte from stdin, or `nil` at EOF.
func readOneByte() -> UInt8? {
    let data = standardInput.readData(ofLength: 1)
    return data.first
}

/// Reads one `Content-Length`-framed JSON-RPC message body from stdin.
func readMessage() -> Data? {
    let terminator = Data("\r\n\r\n".utf8)
    var headerBytes = Data()
    while true {
        guard let byte = readOneByte() else { return nil }
        headerBytes.append(byte)
        if headerBytes.count >= terminator.count, headerBytes.suffix(terminator.count) == terminator {
            break
        }
    }
    guard let headerText = String(data: headerBytes, encoding: .utf8) else { return nil }

    var contentLength = 0
    for line in headerText.split(separator: "\r\n") {
        guard let colonIndex = line.firstIndex(of: ":") else { continue }
        let name = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
        guard name.caseInsensitiveCompare("Content-Length") == .orderedSame else { continue }
        let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
        contentLength = Int(value) ?? 0
    }

    return standardInput.readData(ofLength: contentLength)
}

/// Writes one JSON payload to stdout with `Content-Length` framing.
func writeMessage(payload: Data) {
    var framed = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
    framed.append(payload)
    standardOutput.write(framed)
}

/// One request read from stdin: its JSON-RPC id, and (if present) the
/// `params.textDocument.uri` it named — enough for `respond` steps to
/// target either by read order (`which`) or by request identity (`uri`).
struct ReadRequest {
    let id: Any
    let uri: String?
}

/// Extracts the JSON-RPC `id` field from a raw request message.
func requestID(from data: Data) -> Any? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object["id"]
}

/// Extracts `params.textDocument.uri` from a raw request message, if present.
func requestDocumentURI(from data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let params = object["params"] as? [String: Any],
        let textDocument = params["textDocument"] as? [String: Any]
    else {
        return nil
    }
    return textDocument["uri"] as? String
}

guard CommandLine.arguments.count > 1,
    let scriptData = CommandLine.arguments[1].data(using: .utf8),
    let steps = try? JSONSerialization.jsonObject(with: scriptData) as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("scripted-lsp-server: missing or invalid script argument\n".utf8))
    exit(1)
}

var requestsReadSoFar: [ReadRequest] = []

for step in steps {
    guard let action = step["action"] as? String else { continue }
    switch action {
    case "read":
        guard let message = readMessage(), let id = requestID(from: message) else {
            FileHandle.standardError.write(Data("scripted-lsp-server: expected a request, got EOF\n".utf8))
            exit(1)
        }
        requestsReadSoFar.append(ReadRequest(id: id, uri: requestDocumentURI(from: message)))

    case "respond":
        let result = step["result"] ?? NSNull()
        let targetID: Any
        if let uri = step["uri"] as? String {
            guard let matched = requestsReadSoFar.first(where: { $0.uri == uri }) else {
                FileHandle.standardError.write(Data("scripted-lsp-server: no request read for uri \(uri)\n".utf8))
                exit(1)
            }
            targetID = matched.id
        } else {
            let which = step["which"] as? Int ?? 0
            targetID = requestsReadSoFar[which].id
        }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": targetID, "result": result]
        if let payload = try? JSONSerialization.data(withJSONObject: envelope) {
            writeMessage(payload: payload)
        }

    case "notify":
        let method = step["method"] as? String ?? ""
        let params = step["params"] ?? [String: Any]()
        let envelope: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let payload = try? JSONSerialization.data(withJSONObject: envelope) {
            writeMessage(payload: payload)
        }

    case "hang":
        while true {
            Thread.sleep(forTimeInterval: 3600)
        }

    default:
        break
    }
}
