import Foundation

// The `Content-Length` framing of the JSON-RPC byte stream between this package and a
// language server.
//
// This file imports only Foundation and refers to no other declaration of the package. Keep it
// so: the scripted language server of the tests (`Tests/.../Support/scripted-lsp-server.swift`)
// runs as one script file, and the tests join this file with the script before they start it.
// Thus the server and the client use the same header parser.

/// The `Content-Length` framing of JSON-RPC messages for the wire.
///
/// `Wire.swift` adds the decoders of the JSON-RPC envelopes to this namespace.
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
}

/// An error in the framing of the byte stream from a language server.
///
/// After each of these errors the decoder does not know where the next message starts, thus the
/// stream is out of step. The decoder does not read the next bytes as a header, and the caller
/// must close the connection.
///
/// The cases hold no associated text, thus a log record can hold the case name. The bytes of the
/// header never go into a log record.
enum JSONRPCFrameError: Error, Equatable {
    /// The header is not valid UTF-8.
    case headerNotUTF8

    /// The header has no `Content-Length` field.
    case missingContentLength

    /// The `Content-Length` value is not a decimal number of ASCII digits. A negative value, a
    /// value with a sign and an empty value are each not valid.
    case invalidContentLength

    /// The `Content-Length` value is larger than `JSONRPCMessageDecoder.maxContentLength`.
    case contentLengthTooLarge

    /// The header is longer than `JSONRPCMessageDecoder.maxHeaderLength`, or the stream holds
    /// more bytes than that and no header end.
    case headerTooLarge
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
///
/// A header that tells no correct body length makes `append(bytes:)` throw a
/// `JSONRPCFrameError`. The decoder then removes all the bytes that it keeps.
struct JSONRPCMessageDecoder {
    /// The largest `Content-Length` that the decoder accepts: 64 MiB (`64 << 20` bytes). A
    /// larger value makes the decoder keep too many bytes while it waits for the body.
    static let maxContentLength = 64 << 20

    /// The largest header, in bytes, that the decoder accepts: 8 KiB (`8 << 10` bytes). The
    /// header of an LSP message holds one or two short fields, thus a longer header is not valid.
    static let maxHeaderLength = 8 << 10

    /// The name of the header field that holds the length of the body.
    private static let contentLengthFieldName = "Content-Length"

    /// The `\r\n\r\n` sequence separating headers from the JSON body.
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// The `\r\n` sequence that ends each header line.
    private static let headerLineSeparator = "\r\n"

    /// Bytes received but not yet resolved into a complete message.
    private var buffer = Data()

    /// Appends newly received bytes and returns every message completed as
    /// a result.
    ///
    /// On an error the decoder removes all the bytes that it keeps. The messages that this call
    /// decoded before the bad header are lost too: the stream is out of step, and the caller
    /// closes the connection.
    /// - Parameter bytes: The bytes that came from the stream.
    /// - Returns: Each message that is now complete, in stream order.
    /// - Throws: `JSONRPCFrameError` when a header tells no correct body length.
    mutating func append(bytes: Data) throws(JSONRPCFrameError) -> [Data] {
        buffer.append(bytes)

        var messages: [Data] = []
        do {
            while let message = try extractNextMessage() {
                messages.append(message)
            }
        } catch {
            buffer.removeAll()
            throw error
        }
        return messages
    }

    /// Extracts and removes one complete message from the front of
    /// `buffer`, or returns `nil` if the buffered bytes don't yet contain a
    /// full header-plus-body message.
    /// - Throws: `JSONRPCFrameError` when the header at the front of `buffer` is not valid.
    private mutating func extractNextMessage() throws(JSONRPCFrameError) -> Data? {
        guard let headerEnd = buffer.range(of: Self.headerTerminator) else {
            guard buffer.count <= Self.maxHeaderLength else {
                throw .headerTooLarge
            }
            return nil
        }
        let headerBytes = buffer[buffer.startIndex..<headerEnd.lowerBound]
        let contentLength = try Self.parseContentLength(fromHeader: headerBytes)

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
    /// and are ignored. The first `Content-Length` field gives the length.
    /// - Parameter headerBytes: The header, with no `\r\n\r\n` end.
    /// - Returns: The length of the body, in bytes. It is zero or more and not larger than
    ///   `maxContentLength`.
    /// - Throws: `JSONRPCFrameError` when the header is too long, is not UTF-8, has no
    ///   `Content-Length` field, or has a value that is not valid or too large.
    private static func parseContentLength(fromHeader headerBytes: Data) throws(JSONRPCFrameError) -> Int {
        guard headerBytes.count <= maxHeaderLength else {
            throw .headerTooLarge
        }
        guard let headerText = String(data: headerBytes, encoding: .utf8) else {
            throw .headerNotUTF8
        }
        guard let value = contentLengthValue(inHeader: headerText) else {
            throw .missingContentLength
        }
        guard !value.isEmpty, value.allSatisfy(\.isASCIIDigit), let contentLength = Int(value) else {
            throw .invalidContentLength
        }
        guard contentLength <= maxContentLength else {
            throw .contentLengthTooLarge
        }
        return contentLength
    }

    /// Finds the value of the first `Content-Length` field of a header.
    /// - Parameter headerText: The header, with no `\r\n\r\n` end.
    /// - Returns: The value with no whitespace at its two ends, or `nil` when the header has no
    ///   `Content-Length` field.
    private static func contentLengthValue(inHeader headerText: String) -> String? {
        for line in headerText.split(separator: headerLineSeparator) {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare(contentLengthFieldName) == .orderedSame else { continue }
            return line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

extension Character {
    /// Whether this character is one of the ASCII digits `0` to `9`.
    ///
    /// `Character.isNumber` is also true for digits of other scripts, which `Int(_:)` does not
    /// parse, and `Int(_:)` accepts a leading sign, which a `Content-Length` must not have.
    fileprivate var isASCIIDigit: Bool {
        isASCII && isWholeNumber
    }
}
