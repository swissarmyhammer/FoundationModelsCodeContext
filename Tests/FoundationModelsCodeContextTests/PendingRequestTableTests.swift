import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Unit tests for `PendingRequestTable` (`Sources/FoundationModelsCodeContext/LSP/ProcessLanguageServerConnection.swift`),
/// the lock-guarded id -> `CheckedContinuation` table `ProcessLanguageServerConnection` uses to
/// match JSON-RPC responses back to the request that's awaiting them.
///
/// These are unit tests rather than integration tests against a real child process because the
/// bug they guard against is a scheduling race — a response resolved before its request finishes
/// registering a continuation — that only a direct, ordering-controlled call sequence can force
/// deterministically. Reproducing it via a real subprocess would mean winning a microsecond-scale
/// race on demand, which `ConnectionTests.swift`'s `outOfOrderResponsesAreMatchedByIDNotArrivalOrder()`
/// cannot do (see task `^vhcye6y`'s investigation: this exact race, manifesting only under the
/// scheduling pressure of several hundred concurrently-running tests, was the root cause of a
/// full-suite hang that never reproduced in isolation).
struct PendingRequestTableTests {
    /// The id of the request that a test sends.
    private static let requestID = 7

    /// The id of a second request, beside `requestID`.
    private static let otherRequestID = 2

    /// The error that a timed-out request gets.
    private static let timeoutError = CodeContextError.timeout(ProcessLanguageServerConnection.defaultRequestTimeout)

    /// A response message for the request `id`, with `result` as its result text.
    /// - Parameters:
    ///   - id: The JSON-RPC id that the response answers.
    ///   - result: The JSON text of the `result` field.
    /// - Returns: The raw response message bytes.
    private static func response(id: Int, result: String) -> Data {
        Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8)
    }

    /// Registers a continuation for `id`, gives `fresh` to `resolveOrBuffer(id:response:)` right
    /// after the registration, and gives the response that the continuation gets.
    ///
    /// The continuation gets a buffered response when the table holds one for `id`, and `fresh`
    /// when it holds none. Thus a test that expects `fresh` proves that the table buffered nothing
    /// for `id`, and the call can never wait for ever.
    /// - Parameters:
    ///   - table: The table under test.
    ///   - id: The JSON-RPC id to register.
    ///   - fresh: The response that arrives after the registration.
    /// - Returns: The response that the continuation gets.
    private static func registerAndReceive(in table: PendingRequestTable, id: Int, fresh: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            table.register(id: id, continuation: continuation)
            table.resolveOrBuffer(id: id, response: fresh)
        }
    }

    /// Sends the request `id`, registers its continuation, and times it out.
    /// - Parameters:
    ///   - table: The table under test.
    ///   - id: The JSON-RPC id of the request that times out.
    private static func timeOutRegisteredRequest(in table: PendingRequestTable, id: Int) async {
        table.expectResponse(id: id)
        let error = await #expect(throws: CodeContextError.self) {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                table.register(id: id, continuation: continuation)
                #expect(table.timeOut(id: id, with: Self.timeoutError))
            }
        }
        #expect(error?.caseName == "timeout")
    }

    @Test
    func registerThenResolveDeliversTheResponseToTheContinuation() async throws {
        let table = PendingRequestTable()
        let response = Self.response(id: Self.requestID, result: "null")
        table.expectResponse(id: Self.requestID)

        let delivered = try await Self.registerAndReceive(in: table, id: Self.requestID, fresh: response)

        #expect(delivered == response)
    }

    /// The regression case: a response can legitimately arrive — via `resolveOrBuffer(id:response:)`,
    /// called from the reader loop — *before* the request's own continuation has finished
    /// registering, because writing a request to the wire and registering a continuation to await
    /// its reply are two separate steps with no ordering enforced between them. Before this
    /// buffering existed, `resolveOrBuffer`'s predecessor (a plain `resolve` whose `Bool` result
    /// `route()` never checked) silently discarded a response that arrived with nothing yet
    /// registered, orphaning the continuation that registered afterward: nothing but that
    /// specific request's own timeout task would ever resume it, and if that task's own wakeup was
    /// starved by the very same scheduling pressure that lost the race, the continuation — and the
    /// whole `Task` awaiting it — hung forever.
    @Test
    func resolveBeforeRegisterStillDeliversTheResponseOnceRegistered() async throws {
        let table = PendingRequestTable()
        let response = Self.response(id: Self.requestID, result: #"{"ok":true}"#)
        table.expectResponse(id: Self.requestID)

        // The response arrives first — nothing has registered a continuation for the id yet.
        #expect(table.resolveOrBuffer(id: Self.requestID, response: response) == .buffered)

        // Registering afterward must still deliver the already-arrived response immediately,
        // not hang waiting for a resolution that has already happened.
        let delivered = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            table.register(id: Self.requestID, continuation: continuation)
        }

        #expect(delivered == response)
    }

    @Test
    func aBufferedEarlyResponseForOneIDDoesNotAffectAnotherIDsNormalInOrderFlow() async throws {
        let table = PendingRequestTable()
        let responseForRequest = Self.response(id: Self.requestID, result: "1")
        let responseForOther = Self.response(id: Self.otherRequestID, result: "2")
        table.expectResponse(id: Self.requestID)
        table.expectResponse(id: Self.otherRequestID)

        // The response of the other request arrives before anything registers for it, which
        // buffers it — this must not disturb the first request, which registers and resolves
        // normally (register before resolve) right after.
        table.resolveOrBuffer(id: Self.otherRequestID, response: responseForOther)

        let deliveredFirst = try await Self.registerAndReceive(in: table, id: Self.requestID, fresh: responseForRequest)
        #expect(deliveredFirst == responseForRequest)

        // The earlier-buffered response must still be delivered once something registers for it.
        let deliveredSecond = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            table.register(id: Self.otherRequestID, continuation: continuation)
        }
        #expect(deliveredSecond == responseForOther)
    }

    @Test
    func timeOutReturnsFalseAndDoesNotBufferWhenNothingIsRegistered() {
        let table = PendingRequestTable()

        let isTimedOut = table.timeOut(id: Self.requestID, with: Self.timeoutError)

        #expect(isTimedOut == false)
    }

    @Test
    func failAllDiscardsABufferedEarlyResponseSoALaterRegistrationDoesNotReceiveIt() async throws {
        let table = PendingRequestTable()
        let staleResponse = Self.response(id: Self.requestID, result: #""stale""#)
        let freshResponse = Self.response(id: Self.requestID, result: #""fresh""#)
        table.expectResponse(id: Self.requestID)

        table.resolveOrBuffer(id: Self.requestID, response: staleResponse)
        table.failAll(with: CodeContextError.notRunning)

        // Register again for the same id, as a brand new request reusing an id would (ids are
        // per-connection monotonic in practice, but the table itself doesn't assume that). If
        // `failAll` had left the stale buffered response in place instead of discarding it, this
        // would resolve immediately with `staleResponse` instead of `freshResponse`.
        let delivered = try await Self.registerAndReceive(in: table, id: Self.requestID, fresh: freshResponse)

        #expect(delivered == freshResponse)
    }

    @Test
    func aLateResponseAfterATimeoutIsDroppedAndIsNotBuffered() async throws {
        let table = PendingRequestTable()
        let lateResponse = Self.response(id: Self.requestID, result: #""late""#)
        let freshResponse = Self.response(id: Self.requestID, result: #""fresh""#)
        await Self.timeOutRegisteredRequest(in: table, id: Self.requestID)

        #expect(table.resolveOrBuffer(id: Self.requestID, response: lateResponse) == .droppedLate)

        // A buffered late response would answer this registration at once.
        let delivered = try await Self.registerAndReceive(in: table, id: Self.requestID, fresh: freshResponse)
        #expect(delivered == freshResponse)
    }

    @Test
    func aResponseForAnIDThatWasNeverSentIsDroppedAndIsNotBuffered() async throws {
        let table = PendingRequestTable()
        let unknownResponse = Self.response(id: Self.requestID, result: #""unknown""#)
        let freshResponse = Self.response(id: Self.requestID, result: #""fresh""#)

        #expect(table.resolveOrBuffer(id: Self.requestID, response: unknownResponse) == .droppedUnknown)

        let delivered = try await Self.registerAndReceive(in: table, id: Self.requestID, fresh: freshResponse)
        #expect(delivered == freshResponse)
    }

    @Test
    func aSecondResponseForTheSameIDIsDroppedAndIsNotBuffered() async throws {
        let table = PendingRequestTable()
        let firstResponse = Self.response(id: Self.requestID, result: #""first""#)
        let secondResponse = Self.response(id: Self.requestID, result: #""second""#)
        table.expectResponse(id: Self.requestID)
        _ = try await Self.registerAndReceive(in: table, id: Self.requestID, fresh: firstResponse)

        #expect(table.resolveOrBuffer(id: Self.requestID, response: secondResponse) == .droppedUnknown)
    }

    @Test
    func anAbandonedRequestDoesNotBufferItsResponse() {
        let table = PendingRequestTable()
        let response = Self.response(id: Self.requestID, result: "null")
        table.expectResponse(id: Self.requestID)

        table.abandon(id: Self.requestID)

        #expect(table.resolveOrBuffer(id: Self.requestID, response: response) == .droppedUnknown)
    }

    @Test
    func theTimedOutIDsAreBoundedAndTheOldestIDGoesFirst() async {
        let table = PendingRequestTable()
        let oldestID = 0
        let newestID = oldestID + PendingRequestTable.timedOutIDLimit
        for id in oldestID...newestID {
            await Self.timeOutRegisteredRequest(in: table, id: id)
        }

        // The table keeps `timedOutIDLimit` ids, thus the oldest id is no longer known.
        #expect(table.resolveOrBuffer(id: oldestID, response: Self.response(id: oldestID, result: "null")) == .droppedUnknown)
        #expect(table.resolveOrBuffer(id: newestID, response: Self.response(id: newestID, result: "null")) == .droppedLate)
    }
}
