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
    @Test
    func registerThenResolveDeliversTheResponseToTheContinuation() async throws {
        let table = PendingRequestTable()
        let response = Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8)

        let delivered = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            table.register(id: 1, continuation: continuation)
            table.resolveOrBuffer(id: 1, response: response)
        }

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
        let response = Data(#"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#.utf8)

        // The response arrives first — nothing has registered a continuation for id 7 yet.
        table.resolveOrBuffer(id: 7, response: response)

        // Registering afterward must still deliver the already-arrived response immediately,
        // not hang waiting for a resolution that has already happened.
        let delivered = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            table.register(id: 7, continuation: continuation)
        }

        #expect(delivered == response)
    }

    @Test
    func aBufferedEarlyResponseForOneIDDoesNotAffectAnotherIDsNormalInOrderFlow() async throws {
        let table = PendingRequestTable()
        let responseForOne = Data(#"{"jsonrpc":"2.0","id":1,"result":1}"#.utf8)
        let responseForTwo = Data(#"{"jsonrpc":"2.0","id":2,"result":2}"#.utf8)

        // id 2's response arrives before anything registers for it, buffering it — this must not
        // disturb id 1, which registers and resolves normally (register before resolve) right
        // after.
        table.resolveOrBuffer(id: 2, response: responseForTwo)

        let deliveredFirst = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            table.register(id: 1, continuation: continuation)
            table.resolveOrBuffer(id: 1, response: responseForOne)
        }
        #expect(deliveredFirst == responseForOne)

        // id 2's earlier-buffered response must still be delivered once something registers for it.
        let deliveredSecond = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            table.register(id: 2, continuation: continuation)
        }
        #expect(deliveredSecond == responseForTwo)
    }

    @Test
    func resolveReturnsFalseAndDoesNotBufferWhenNothingIsRegistered() {
        let table = PendingRequestTable()

        let resolved = table.resolve(id: 99, with: .failure(CodeContextError.timeout(.seconds(30))))

        #expect(resolved == false)
    }

    @Test
    func failAllDiscardsABufferedEarlyResponseSoALaterRegistrationDoesNotReceiveIt() async throws {
        let table = PendingRequestTable()
        let staleResponse = Data(#"{"jsonrpc":"2.0","id":3,"result":"stale"}"#.utf8)
        let freshResponse = Data(#"{"jsonrpc":"2.0","id":3,"result":"fresh"}"#.utf8)

        table.resolveOrBuffer(id: 3, response: staleResponse)
        table.failAll(with: CodeContextError.notRunning)

        // Register again for the same id, as a brand new request reusing an id would (ids are
        // per-connection monotonic in practice, but the table itself doesn't assume that). If
        // `failAll` had left the stale buffered response in place instead of discarding it, this
        // would resolve immediately with `staleResponse` instead of waiting to be resolved
        // normally like any other freshly-registered request — `resolveOrBuffer` right after
        // registering supplies that normal resolution, so this can never hang either way.
        let delivered = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            table.register(id: 3, continuation: continuation)
            table.resolveOrBuffer(id: 3, response: freshResponse)
        }

        #expect(delivered == freshResponse)
    }
}
