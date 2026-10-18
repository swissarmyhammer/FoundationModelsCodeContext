import Foundation

/// The reply of the client to one request that the language server sends to the client.
///
/// A server can send requests to the client, for example `workspace/configuration` or
/// `window/workDoneProgress/create`, and some servers stop and wait until the client replies.
/// Thus the client replies to each server request:
///
/// - `workspace/configuration` gets an array of `null`, one `null` for each item. `null`
///   tells the server to use its default configuration.
/// - `client/registerCapability`, `client/unregisterCapability` and
///   `window/workDoneProgress/create` get the result `null`, which is the success result of
///   these methods.
/// - Each other method gets the error `MethodNotFound` (`-32601`).
///
/// The reply holds the id of the server request in the same form (number or string).
enum ServerRequestReply {
    /// The JSON-RPC error code that tells the server that the client has no such method.
    static let methodNotFoundCode = -32601

    /// The method that asks the client for configuration values.
    static let configurationMethod = "workspace/configuration"

    /// The methods whose success result is `null`. The client accepts each of them and keeps
    /// no state for them.
    static let nullResultMethods: Set<String> = [
        "client/registerCapability",
        "client/unregisterCapability",
        "window/workDoneProgress/create",
    ]

    /// The JSON-RPC 2.0 reply to one server request: a `result` or an `error`.
    private struct Envelope: Encodable {
        /// The outcome of the server request.
        enum Outcome {
            /// The request succeeded with this result.
            case result(JSONValue)

            /// The request failed with this error.
            case error(JSONRPCErrorPayload)
        }

        let id: JSONRPCID
        let outcome: Outcome

        private enum CodingKeys: String, CodingKey {
            case jsonrpc
            case id
            case result
            case error
        }

        /// Encodes `result` also when it is `null`: a reply with no `result` and no `error`
        /// is not a valid JSON-RPC response.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("2.0", forKey: .jsonrpc)
            try container.encode(id, forKey: .id)
            switch outcome {
            case .result(let result): try container.encode(result, forKey: .result)
            case .error(let error): try container.encode(error, forKey: .error)
            }
        }
    }

    /// The params of `workspace/configuration`. Only the count of `items` has an effect.
    private struct ConfigurationParams: Decodable {
        let items: [JSONValue]?
    }

    /// The `params` member of a server request.
    private struct ConfigurationRequest: Decodable {
        let params: ConfigurationParams?
    }

    /// Makes the JSON payload of the reply to one server request.
    /// - Parameters:
    ///   - message: The raw bytes of the server request. Only `workspace/configuration` reads
    ///     them, for the count of its items.
    ///   - id: The id of the server request. The reply holds the same id.
    ///   - method: The method of the server request.
    /// - Returns: The JSON payload of the reply, not framed.
    /// - Throws: An `EncodingError` if the reply cannot be encoded.
    static func payload(answering message: Data, id: JSONRPCID, method: String) throws -> Data {
        try JSONEncoder().encode(Envelope(id: id, outcome: outcome(answering: message, method: method)))
    }

    /// Gives the outcome of one server request.
    /// - Parameters:
    ///   - message: The raw bytes of the server request.
    ///   - method: The method of the server request.
    /// - Returns: The result or the error that the reply holds.
    private static func outcome(answering message: Data, method: String) -> Envelope.Outcome {
        if method == configurationMethod {
            return .result(.array(Array(repeating: .null, count: configurationItemCount(in: message))))
        }
        if nullResultMethods.contains(method) {
            return .result(.null)
        }
        return .error(JSONRPCErrorPayload(code: methodNotFoundCode, message: "method not found: \(method)"))
    }

    /// Counts the `params.items` of a `workspace/configuration` request.
    /// - Parameter message: The raw bytes of the request.
    /// - Returns: The count of the items, or `0` when the request has no `items` array. A reply
    ///   to such a request is the empty array.
    private static func configurationItemCount(in message: Data) -> Int {
        let request = try? JSONDecoder().decode(ConfigurationRequest.self, from: message)
        return request?.params?.items?.count ?? 0
    }
}
