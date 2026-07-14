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
//     (absent for a fire-and-forget notification) and (if present) its
//     `params.textDocument.uri` (appended to an ordered list of "requests
//     read so far" — a read notification occupies a slot in this list too,
//     just one with no `id`, so a later "respond" step must target the
//     index of an actual request, not a notification).
//
//   {"action": "read", "expectMethod": <String>}
//     Same as plain "read", but additionally asserts the message's
//     top-level `method` field equals `expectMethod`, exiting with a
//     stderr message otherwise — lets a script verify which notification
//     or request shape the client actually sent (e.g. distinguishing
//     `initialized`'s no-payload notification from a `textDocument/*`
//     one) rather than merely consuming a message of any shape.
//
//   {"action": "read", "expectURI": <String>}
//     Same as plain "read", but additionally asserts the message's
//     `params.textDocument.uri` equals `expectURI`, exiting with a stderr
//     message otherwise. Combines with `expectMethod` on the same step.
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
//   {"action": "stderr", "text": <String>}
//     Writes `text` to stderr, unframed — used to drive `ConnectionTests`'
//     `recentStderrTail()` scenario.
//
// Deliberately does not import FoundationModelsCodeContext: this runs as an independent
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

/// One message read from stdin: its JSON-RPC id (`nil` for a fire-and-forget
/// notification, which carries no id), and (if present) the
/// `params.textDocument.uri` it named — enough for `respond` steps to
/// target either by read order (`which`) or by request identity (`uri`).
struct ReadRequest {
    let id: Any?
    let uri: String?
}

/// Extracts the JSON-RPC `id` field from a raw message, if present (absent on
/// a fire-and-forget notification).
func requestID(from data: Data) -> Any? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object["id"]
}

/// Extracts the JSON-RPC `method` field from a raw message, if present
/// (absent on a response).
func requestMethod(from data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object["method"] as? String
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

/// Asserts a "read" step's `expectMethod` (if present) against the actual
/// message's `method` field, exiting with a stderr message on mismatch.
func assertExpectedMethod(expecting expectMethod: String, message: Data) {
    let actualMethod = requestMethod(from: message)
    guard actualMethod == expectMethod else {
        FileHandle.standardError.write(Data("scripted-lsp-server: expected method \(expectMethod), got \(actualMethod ?? "nil")\n".utf8))
        exit(1)
    }
}

/// Asserts a "read" step's `expectURI` (if present) against the actual
/// message's `params.textDocument.uri`, exiting with a stderr message on
/// mismatch.
func assertExpectedURI(expecting expectURI: String, message: Data) {
    let actualURI = requestDocumentURI(from: message)
    guard actualURI == expectURI else {
        FileHandle.standardError.write(Data("scripted-lsp-server: expected uri \(expectURI), got \(actualURI ?? "nil")\n".utf8))
        exit(1)
    }
}

/// Validates a "read" step's optional `expectMethod`/`expectURI` assertions
/// against the actual message read from stdin.
func validateReadExpectations(step: [String: Any], message: Data) {
    if let expectMethod = step["expectMethod"] as? String {
        assertExpectedMethod(expecting: expectMethod, message: message)
    }
    if let expectURI = step["expectURI"] as? String {
        assertExpectedURI(expecting: expectURI, message: message)
    }
}

/// Resolves the JSON-RPC id for a "respond" step keyed by `uri`: whichever
/// request read so far named that document. Exits with a stderr message if
/// no such request was read, or it was a notification with no id.
func resolveTargetID(forURI uri: String, requestsReadSoFar: [ReadRequest]) -> Any {
    guard let matched = requestsReadSoFar.first(where: { $0.uri == uri }), let matchedID = matched.id else {
        FileHandle.standardError.write(Data("scripted-lsp-server: no request read for uri \(uri)\n".utf8))
        exit(1)
    }
    return matchedID
}

/// Resolves the JSON-RPC id for a "respond" step keyed by `which`: the
/// request at that 0-based read-order index. Exits with a stderr message if
/// that request was a notification with no id.
func resolveTargetID(forIndex which: Int, requestsReadSoFar: [ReadRequest]) -> Any {
    guard let whichID = requestsReadSoFar[which].id else {
        FileHandle.standardError.write(Data("scripted-lsp-server: request at index \(which) has no id (it was a notification)\n".utf8))
        exit(1)
    }
    return whichID
}

/// Resolves the JSON-RPC id for a "respond" step, by `uri` if present,
/// otherwise by `which` (defaulting to index 0).
func resolveTargetID(step: [String: Any], requestsReadSoFar: [ReadRequest]) -> Any {
    if let uri = step["uri"] as? String {
        return resolveTargetID(forURI: uri, requestsReadSoFar: requestsReadSoFar)
    }
    let which = step["which"] as? Int ?? 0
    return resolveTargetID(forIndex: which, requestsReadSoFar: requestsReadSoFar)
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
        guard let message = readMessage() else {
            FileHandle.standardError.write(Data("scripted-lsp-server: expected a message, got EOF\n".utf8))
            exit(1)
        }
        validateReadExpectations(step: step, message: message)
        requestsReadSoFar.append(ReadRequest(id: requestID(from: message), uri: requestDocumentURI(from: message)))

    case "respond":
        let result = step["result"] ?? NSNull()
        let targetID = resolveTargetID(step: step, requestsReadSoFar: requestsReadSoFar)
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

    case "stderr":
        let text = step["text"] as? String ?? ""
        FileHandle.standardError.write(Data(text.utf8))

    default:
        break
    }
}
