import Foundation
import Testing

/// Tests for `waitUntil(timeout:pollInterval:_:)`, the one polling wait of the
/// test target.
///
/// The suites use this wait for work that runs in a task that the test cannot
/// await. These tests make sure that the wait stops at the first `true`, that a
/// wait with a timeout gives `false` when the time elapses, and that a cancelled
/// wait throws and does not poll for ever.
struct WaitUntilTests {
    /// The number of the check that first gives `true` in the test of the stop.
    private static let checkThatSucceeds = 3

    /// The timeout of the test that waits for a condition that never occurs.
    /// It is short, thus the test is fast.
    private static let shortTimeout: Duration = .milliseconds(20)

    @Test
    func theWaitStopsAtTheFirstCheckThatGivesTrue() async throws {
        var checkCount = 0

        let isDone = try await waitUntil {
            checkCount += 1
            return checkCount == Self.checkThatSucceeds
        }

        #expect(isDone)
        #expect(checkCount == Self.checkThatSucceeds)
    }

    @Test
    func aWaitWithATimeoutGivesFalseWhenTheTimeElapses() async throws {
        let start = ContinuousClock.now

        let isDone = try await waitUntil(timeout: Self.shortTimeout) { false }

        #expect(!isDone)
        #expect(start.duration(to: .now) >= Self.shortTimeout)
    }

    @Test
    func aCancelledWaitWithNoTimeoutThrowsCancellationError() async {
        let wait = Task { try await waitUntil { false } }

        wait.cancel()

        await #expect(throws: CancellationError.self) {
            try await wait.value
        }
    }

    @Test
    func theWaitGivesTheErrorOfTheCheck() async {
        await #expect(throws: CocoaError.self) {
            try await waitUntil { throw CocoaError(.fileNoSuchFile) }
        }
    }
}
