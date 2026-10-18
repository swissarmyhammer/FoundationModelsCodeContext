import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `ServerRequestReply`: the reply of the client to each request that a language
/// server sends to the client.
struct ServerRequestReplyTests {
    /// The number id of the server request in these tests.
    private static let requestNumber = 7

    /// The id `requestNumber` as the decoded reply holds it.
    private static let requestIDValue: JSONValue = .number(Double(requestNumber))

    /// The methods that get the result `null`.
    static let nullResultMethods = [
        "client/registerCapability",
        "client/unregisterCapability",
        "window/workDoneProgress/create",
    ]

    /// Makes the reply to one server request and decodes it as one JSON value.
    /// - Parameters:
    ///   - method: The method of the server request.
    ///   - id: The id of the server request.
    ///   - paramsJSON: The JSON text of the params of the server request.
    /// - Returns: The decoded reply.
    /// - Throws: The error of the reply or of the decode.
    private static func reply(
        to method: String,
        id: JSONRPCID = .number(requestNumber),
        paramsJSON: String = "{}"
    ) throws -> JSONValue {
        let idJSON = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
        let message = Data(#"{"jsonrpc":"2.0","id":\#(idJSON),"method":"\#(method)","params":\#(paramsJSON)}"#.utf8)
        let payload = try ServerRequestReply.payload(answering: message, id: id, method: method)
        return try JSONDecoder().decode(JSONValue.self, from: payload)
    }

    /// The JSON value of a reply with `id` that holds `result`.
    private static func resultReply(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    @Test
    func aConfigurationRequestGetsOneNullForEachItem() throws {
        let reply = try Self.reply(
            to: "workspace/configuration",
            paramsJSON: #"{"items":[{"section":"python"},{"section":"rust"},{}]}"#
        )

        #expect(reply == Self.resultReply(id: Self.requestIDValue, result: .array([.null, .null, .null])))
    }

    @Test
    func aConfigurationRequestWithNoItemsGetsAnEmptyArray() throws {
        let reply = try Self.reply(to: "workspace/configuration")

        #expect(reply == Self.resultReply(id: Self.requestIDValue, result: .array([])))
    }

    @Test(arguments: nullResultMethods)
    func aRegistrationOrProgressRequestGetsANullResult(_ method: String) throws {
        let reply = try Self.reply(to: method)

        #expect(reply == Self.resultReply(id: Self.requestIDValue, result: .null))
    }

    @Test
    func anUnknownRequestGetsAMethodNotFoundError() throws {
        let reply = try Self.reply(to: "custom/unknownMethod")

        let error: JSONValue = .object([
            "code": .number(Double(TestJSON.methodNotFoundCode)),
            "message": .string("method not found: custom/unknownMethod"),
        ])
        #expect(reply == .object(["jsonrpc": .string("2.0"), "id": Self.requestIDValue, "error": error]))
    }

    @Test
    func aStringIDComesBackAsTheSameString() throws {
        let reply = try Self.reply(to: "window/workDoneProgress/create", id: .string("progress-1"))

        #expect(reply == Self.resultReply(id: .string("progress-1"), result: .null))
    }
}
