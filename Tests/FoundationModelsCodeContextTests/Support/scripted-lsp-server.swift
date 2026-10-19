//
// scripted-lsp-server.swift
//
// A tiny Content-Length-framed JSON-RPC stub, run as a script
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
//   {"action": "read", "expectID": <any JSON>, "expectResult": <any JSON>, "expectErrorCode": <Int>}
//     Same as plain "read", but additionally asserts the `id`, the `result`
//     and the `error.code` of the message. Each key is optional. Use these
//     keys to read the reply of the client to a "request" step. A JSON
//     number never equals a JSON string: the id 1 is not the id "1".
//
//   {"action": "read", "expectInitializationOptions": <any JSON>}
//     Same as plain "read", but additionally asserts the
//     `params.initializationOptions` of the message. An absent field reads
//     as `null`, thus the value `null` accepts an absent field and a `null`
//     field. Use this key to read the `initialize` request of the client.
//
//   {"action": "read", "expectParams": <any JSON>}
//     Same as plain "read", but additionally asserts the `params` of the
//     message. Use this key to read a notification of the client, for
//     example the `$/cancelRequest` notification and the id that it holds.
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
//   {"action": "respondError", "which": <Int>, "code": <Int>, "message": <String>}
//     Writes a framed JSON-RPC error response for the `which`-th request
//     read so far (or for the request that `uri` names, the same as
//     "respond"). The response holds an `error` object with `code` and
//     `message`, and no `result`.
//
//   {"action": "notify", "method": <String>, "params": <any JSON>}
//     Writes a framed JSON-RPC notification (no id), simulating a
//     server-initiated push such as `textDocument/publishDiagnostics`.
//
//   {"action": "request", "id": <Int or String>, "method": <String>, "params": <any JSON>}
//     Writes a framed JSON-RPC request from the server to the client, such as
//     `workspace/configuration`. The client must reply with the same id. Use
//     a "read" step with `expectID` to read that reply.
//
//   {"action": "writeRaw", "text": <String>}
//     Writes the UTF-8 bytes of `text` to stdout with no framing — used to
//     send a bad frame header, for example `Content-Length: -5`, to the
//     connection.
//
//   {"action": "hang"}
//     Reads stdin until EOF and discards each byte, thus the step never
//     answers a pending request. While stdin is open, the process stays
//     alive and stdout stays open — used to drive `ConnectionTests`' timeout
//     scenario. At EOF of stdin the script stops, as a real language server
//     does. Thus a script whose client exits with no `close()` (for example
//     a test binary that crashes) does not stay alive.
//
//   {"action": "stderr", "text": <String>}
//     Writes `text` to stderr, unframed — used to drive `ConnectionTests`'
//     `recentStderrTail()` scenario.
//
//   {"action": "mark", "path": <String>, "text": <String>}
//     Appends `text` and a newline to the file at `path`, and makes the
//     file when it is not there. The file does not go through a pipe of the
//     client, thus a test that reads it learns how far the script ran also
//     when a message on a pipe got lost — used by `ConnectionTests` to tell
//     a script that never started from one that read the request and
//     answered it.
//
//   {"action": "spawnGrandchild", "pidFile": <String>, "exitsAtEndOfInput": <Bool>}
//     Starts a child process of the script — a grandchild of the client —
//     and writes its pid to `pidFile`. The child models the Jedi subprocess
//     of `pylsp`: it is in the process group of the script (no new group),
//     it ignores `SIGTERM`, and its standard input is a pipe whose write end
//     the script keeps open until the script exits. With `exitsAtEndOfInput`
//     true, the child reads that pipe and exits at its end, as Jedi does;
//     otherwise it sleeps, and only `SIGKILL` stops it. Used to prove that a
//     stop of the server kills each process of its group.
//
// Deliberately does not import FoundationModelsCodeContext: this runs as an independent
// process, not linked against the package under test.
//
// The framing code is not in this file. The tests join
// `Sources/FoundationModelsCodeContext/LSP/Framing.swift` with this file into one script file
// (see `ScriptedLSPServerScript` in `Tests/ScriptedLSPServerSupport/`, which the unit tests and
// the integration package both use) and start that file. Thus `JSONRPCFraming` and
// `JSONRPCMessageDecoder` below are the same code that the connection uses, and the package has
// one header parser. This file has no `#!` line, because the joined file starts with
// `Framing.swift`. Do not start this file alone.

import Foundation

let standardInput = FileHandle.standardInput
let standardOutput = FileHandle.standardOutput

/// Reads the framed JSON-RPC messages that the client writes to stdin.
struct StandardInputMessageReader {
    /// The shared decoder of `Framing.swift`.
    private var decoder = JSONRPCMessageDecoder()

    /// The messages that `decoder` decoded and that no "read" step took yet.
    private var decodedMessages: [Data] = []

    /// Reads one `Content-Length`-framed JSON-RPC message body from stdin.
    ///
    /// Exits with a stderr message when a frame header from the client is not valid.
    /// - Returns: The body, or `nil` at EOF.
    mutating func readMessage() -> Data? {
        while decodedMessages.isEmpty {
            let chunk = standardInput.availableData
            guard !chunk.isEmpty else { return nil }
            do {
                decodedMessages = try decoder.append(bytes: chunk)
            } catch {
                FileHandle.standardError.write(Data("scripted-lsp-server: bad frame header: \(error)\n".utf8))
                exit(1)
            }
        }
        return decodedMessages.removeFirst()
    }

    /// Reads stdin until EOF and discards the bytes. The function answers no message.
    ///
    /// A pipe holds a limited number of bytes. The read keeps the pipe empty, thus a write of the
    /// client never blocks.
    func discardUntilEndOfInput() {
        while !standardInput.availableData.isEmpty {}
    }
}

/// Writes one JSON payload to stdout with `Content-Length` framing.
func writeMessage(payload: Data) {
    standardOutput.write(JSONRPCFraming.frame(payload: payload))
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

/// Asserts that the JSON value `actual` of a message equals the JSON value
/// `expected` of a "read" step, exiting with a stderr message otherwise.
///
/// The values come from `JSONSerialization`, thus `isEqual` compares them:
/// a JSON number never equals a JSON string.
func assertJSONValue(_ actual: Any?, equals expected: Any, stepKey: String) {
    guard let actual, (actual as AnyObject).isEqual(expected) else {
        FileHandle.standardError.write(Data("scripted-lsp-server: \(stepKey) \(expected) does not match \(actual ?? "nil")\n".utf8))
        exit(1)
    }
}

/// Validates a "read" step's optional `expectID`/`expectResult`/
/// `expectErrorCode`/`expectInitializationOptions`/`expectParams` assertions
/// against the message that the client wrote.
func validateReplyExpectations(step: [String: Any], message: Data) {
    let object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any] ?? [:]
    let initializationOptions = (object["params"] as? [String: Any])?["initializationOptions"]
    let checks: [(stepKey: String, actual: Any?)] = [
        ("expectID", object["id"]),
        ("expectResult", object["result"]),
        ("expectErrorCode", (object["error"] as? [String: Any])?["code"]),
        ("expectInitializationOptions", initializationOptions ?? NSNull()),
        ("expectParams", object["params"]),
    ]
    for check in checks {
        if let expected = step[check.stepKey] {
            assertJSONValue(check.actual, equals: expected, stepKey: check.stepKey)
        }
    }
}

/// Validates a "read" step's optional `expectMethod`/`expectURI` assertions
/// and its reply assertions against the actual message read from stdin.
func validateReadExpectations(step: [String: Any], message: Data) {
    if let expectMethod = step["expectMethod"] as? String {
        assertExpectedMethod(expecting: expectMethod, message: message)
    }
    if let expectURI = step["expectURI"] as? String {
        assertExpectedURI(expecting: expectURI, message: message)
    }
    validateReplyExpectations(step: step, message: message)
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

/// Writes one JSON-RPC 2.0 message to stdout with `Content-Length` framing.
/// The message holds `fields` beside its `jsonrpc` field.
func writeEnvelope(_ fields: [String: Any]) {
    var envelope: [String: Any] = ["jsonrpc": "2.0"]
    envelope.merge(fields) { _, field in field }
    if let payload = try? JSONSerialization.data(withJSONObject: envelope) {
        writeMessage(payload: payload)
    }
}

/// Writes a framed JSON-RPC response for the request that a "respond" or
/// "respondError" step names. The response holds `fields` beside its
/// `jsonrpc` and `id` fields: a `result` or an `error`.
func writeResponse(step: [String: Any], requestsReadSoFar: [ReadRequest], fields: [String: Any]) {
    var response = fields
    response["id"] = resolveTargetID(step: step, requestsReadSoFar: requestsReadSoFar)
    writeEnvelope(response)
}

/// The seconds that the child of a "spawnGrandchild" step with no
/// `exitsAtEndOfInput` sleeps. Much longer than each test, thus only a kill
/// stops the child in a test.
let grandchildSleepSeconds = 600

/// The input pipe of each child of a "spawnGrandchild" step. The script keeps
/// each write end open, thus a child that reads its input until the end runs
/// until the script exits.
var grandchildInputs: [Pipe] = []

/// Writes `message` to stderr and exits with status 1.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("scripted-lsp-server: \(message)\n".utf8))
    exit(1)
}

/// Starts `/bin/sh -c <command>` with `posix_spawn(2)` in the process group of
/// the script, with `input` as its standard input and the null device as its
/// standard output and standard error. `POSIX_SPAWN_CLOEXEC_DEFAULT` gives
/// the child no other file descriptor of the script, as `subprocess.Popen`
/// with its default `close_fds` does for Jedi.
func spawnInScriptGroup(command: String, input: Pipe) -> pid_t {
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_adddup2(&fileActions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO)
    posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    let arguments = ["/bin/sh", "-c", command].map { strdup($0) } + [nil]
    defer {
        for argument in arguments {
            free(argument)
        }
    }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, "/bin/sh", &fileActions, &attributes, arguments, environ)
    guard result == 0 else {
        fail("spawnGrandchild could not start the child: errno \(result)")
    }
    return pid
}

/// Runs a "spawnGrandchild" step: starts the child that the header comment
/// describes, keeps its input pipe open, and writes its pid to `pidFile`.
func spawnGrandchild(step: [String: Any]) {
    guard let pidFile = step["pidFile"] as? String else {
        fail("spawnGrandchild needs a pidFile")
    }
    let exitsAtEndOfInput = step["exitsAtEndOfInput"] as? Bool ?? false
    let wait = exitsAtEndOfInput ? "cat > /dev/null" : "sleep \(grandchildSleepSeconds)"
    let input = Pipe()
    // `trap '' TERM` sets SIGTERM to ignored, and `exec` keeps an ignored signal ignored.
    let pid = spawnInScriptGroup(command: "trap '' TERM; exec \(wait)", input: input)
    try? input.fileHandleForReading.close()
    grandchildInputs.append(input)
    do {
        try Data("\(pid)".utf8).write(to: URL(fileURLWithPath: pidFile), options: .atomic)
    } catch {
        fail("spawnGrandchild could not write \(pidFile): \(error)")
    }
}

/// Runs a "mark" step: appends its `text` and a newline to the file at its
/// `path`, as the header comment describes.
func appendMark(step: [String: Any]) {
    guard let path = step["path"] as? String else {
        fail("mark needs a path")
    }
    let line = Data(((step["text"] as? String ?? "") + "\n").utf8)
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let handle = FileHandle(forWritingAtPath: path) else {
        fail("mark could not open \(path)")
    }
    handle.seekToEndOfFile()
    handle.write(line)
    try? handle.close()
}

guard CommandLine.arguments.count > 1,
    let scriptData = CommandLine.arguments[1].data(using: .utf8),
    let steps = try? JSONSerialization.jsonObject(with: scriptData) as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("scripted-lsp-server: missing or invalid script argument\n".utf8))
    exit(1)
}

var requestsReadSoFar: [ReadRequest] = []
var messageReader = StandardInputMessageReader()

for step in steps {
    guard let action = step["action"] as? String else { continue }
    switch action {
    case "read":
        guard let message = messageReader.readMessage() else {
            FileHandle.standardError.write(Data("scripted-lsp-server: expected a message, got EOF\n".utf8))
            exit(1)
        }
        validateReadExpectations(step: step, message: message)
        requestsReadSoFar.append(ReadRequest(id: requestID(from: message), uri: requestDocumentURI(from: message)))

    case "respond":
        writeResponse(step: step, requestsReadSoFar: requestsReadSoFar, fields: ["result": step["result"] ?? NSNull()])

    case "respondError":
        let error: [String: Any] = ["code": step["code"] ?? 0, "message": step["message"] ?? ""]
        writeResponse(step: step, requestsReadSoFar: requestsReadSoFar, fields: ["error": error])

    case "notify":
        writeEnvelope(["method": step["method"] ?? "", "params": step["params"] ?? [String: Any]()])

    case "request":
        writeEnvelope(["id": step["id"] ?? NSNull(), "method": step["method"] ?? "", "params": step["params"] ?? [String: Any]()])

    case "writeRaw":
        let text = step["text"] as? String ?? ""
        standardOutput.write(Data(text.utf8))

    case "hang":
        messageReader.discardUntilEndOfInput()
        exit(0)

    case "stderr":
        let text = step["text"] as? String ?? ""
        FileHandle.standardError.write(Data(text.utf8))

    case "mark":
        appendMark(step: step)

    case "spawnGrandchild":
        spawnGrandchild(step: step)

    default:
        break
    }
}
