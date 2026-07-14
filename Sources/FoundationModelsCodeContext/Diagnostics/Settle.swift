import Foundation

/// The result of a `Settle.settle(session:uris:...)`/`settleStream(...)` call:
/// either every watched uri's diagnostics quiesced within the settle window,
/// or the hard timeout fired first.
///
/// Port of `swissarmyhammer-diagnostics`'s `settle::SettleOutcome`.
enum SettleOutcome: Sendable, Equatable {
    /// Every watched uri quiesced: no update arrived for a full settle
    /// window before the hard timeout. Carries the latest known diagnostics
    /// per watched uri.
    case settled([DocumentURI: [Diagnostic]])

    /// The hard timeout elapsed before the watched uris quiesced.
    case pending
}

/// The debounce/hard-timeout quiescence engine: waits for a burst of
/// `publishDiagnostics` pushes for a set of watched documents to go quiet.
///
/// Port of `swissarmyhammer-diagnostics`'s `settle.rs`. The Rust reference
/// races a `tokio::sync::broadcast::Receiver<DiagnosticUpdate>` against two
/// `Timer::sleep` futures in a biased `select!` (hard timeout first, then a
/// received update, then the debounce firing), with a `Lagged` branch that
/// re-snapshots the watched uris' cached diagnostics when the broadcast
/// channel's slow-consumer buffer drops messages.
///
/// This port's `LspSession.diagnosticUpdates()` is backed by
/// `AsyncStream.makeStream(of:)` with its default unbounded buffering
/// policy — every yielded update is delivered to every subscriber, so there
/// is no `Lagged` scenario to guard against and no resync branch to port.
///
/// Racing "wait for the next stream update" directly against a `Clock` sleep
/// inside one `TaskGroup` would require `AsyncStream.Iterator.next()` to
/// reliably unblock the instant its enclosing task is cancelled — a guarantee
/// this port doesn't want to depend on. Instead, a persistent background
/// task drains the stream into `UpdateMailbox`, a small cancellation-safe
/// single-slot notifier modeled directly on `ManualClock`'s own
/// waiter/continuation bookkeeping (see `Tests/FoundationModelsCodeContextTests/Support/ManualClock.swift`),
/// so only `UpdateMailbox.next()` and `Clock.sleep(until:)` — both already
/// cancellation-safe — ever sit inside the per-iteration race.
///
/// The hard timeout is tracked as one absolute deadline computed once up
/// front (`clock.now.advanced(by: hardTimeout)`), re-raced every loop
/// iteration via a fresh `clock.sleep(until:)` call against that same fixed
/// instant — not a relative `sleep(for: hardTimeout)` re-armed each
/// iteration, which would incorrectly extend the hard budget every time the
/// debounce window also restarts. Reaching `.now`/`Instant` arithmetic like
/// this needs a concrete `Clock` type (an `any Clock<Duration>` existential
/// can't name its own `Instant`), so the engine itself is generic over
/// `<C: Clock>`; the public, ergonomic `any Clock<Duration> = ContinuousClock()`
/// surface lives one level up on `DiagnosticsOps.diagnostics(...)`, which
/// forwards its existential `clock` into this generic entry point (Swift
/// implicitly opens the existential for that one call — SE-0352).
enum Settle {
    /// Subscribes to `session`'s diagnostics stream, seeds from its cache,
    /// then waits for `uris` to quiesce.
    ///
    /// Subscribes via `session.diagnosticUpdates()` *before* snapshotting
    /// `session.diagnostics(for:)` for each uri, matching the Rust
    /// reference's ordering: an update that lands in the gap between
    /// subscribing and snapshotting is still captured by the newly
    /// registered subscription, so it is never lost.
    /// - Parameters:
    ///   - session: The session to subscribe to and seed from.
    ///   - uris: The documents to watch; empty settles immediately with an empty result.
    ///   - settleWindow: How long a watched uri must go quiet before settling. Defaults to 300ms.
    ///   - hardTimeout: The maximum time to wait before giving up as pending. Defaults to 5 seconds.
    ///   - clock: The clock the settle window and hard timeout are measured against.
    /// - Returns: `.settled` with the latest per-uri diagnostics once quiesced, or `.pending` at the hard timeout.
    static func settle<Connection: LanguageServerConnection, C: Clock>(
        session: LspSession<Connection>,
        uris: [DocumentURI],
        settleWindow: Duration = .milliseconds(300),
        hardTimeout: Duration = .seconds(5),
        clock: C
    ) async -> SettleOutcome where C.Duration == Duration {
        let watched = Set(uris)
        guard !watched.isEmpty else { return .settled([:]) }

        // Subscribe before snapshotting — see this type's doc comment.
        let stream = await session.diagnosticUpdates()
        var initial: [DocumentURI: [Diagnostic]] = [:]
        for uri in watched {
            initial[uri] = await session.diagnostics(for: uri)
        }

        return await settleStream(
            stream: stream,
            watched: watched,
            initial: initial,
            settleWindow: settleWindow,
            hardTimeout: hardTimeout,
            clock: clock
        )
    }

    /// The pure quiescence loop `settle(session:uris:...)` delegates to,
    /// decoupled from any live session/connection so it can be driven
    /// directly against a bare `AsyncStream` and a `ManualClock` in tests.
    /// - Parameters:
    ///   - stream: The diagnostics update stream to watch.
    ///   - watched: The uris to watch; empty settles immediately with an empty result.
    ///   - initial: The seed diagnostics per watched uri, from the cache snapshot taken before subscribing.
    ///   - settleWindow: How long a watched uri must go quiet before settling.
    ///   - hardTimeout: The maximum time to wait before giving up as pending.
    ///   - clock: The clock the settle window and hard timeout are measured against.
    /// - Returns: `.settled` with the latest per-uri diagnostics once quiesced, or `.pending` at the hard timeout.
    static func settleStream<C: Clock>(
        stream: AsyncStream<DiagnosticUpdate>,
        watched: Set<DocumentURI>,
        initial: [DocumentURI: [Diagnostic]],
        settleWindow: Duration,
        hardTimeout: Duration,
        clock: C
    ) async -> SettleOutcome where C.Duration == Duration {
        guard !watched.isEmpty else { return .settled([:]) }

        var state = initial.filter { watched.contains($0.key) }

        let mailbox = UpdateMailbox()
        let drainTask = Task {
            for await update in stream {
                mailbox.record(update)
            }
            mailbox.markClosed()
        }
        defer { drainTask.cancel() }

        let hardDeadline = clock.now.advanced(by: hardTimeout)
        // Only a *watched* update restarts the debounce window — an update
        // for a uri nobody asked about must be dropped without touching it,
        // matching the Rust reference exactly. Recomputing this on every
        // loop iteration regardless of relevance (rather than only when a
        // watched update actually arrived) would let a stream of irrelevant
        // updates postpone settling indefinitely, which is not what
        // "quiescence for the watched set" means.
        var debounceDeadline = clock.now.advanced(by: settleWindow)

        while true {
            // Checked explicitly before *and* after racing, rather than only
            // trusting whichever task `race(...)` happens to report first:
            // a debounce reset late in the hard-timeout budget can produce a
            // `debounceDeadline` at or past `hardDeadline`, and once both
            // are simultaneously reachable, `TaskGroup.next()` offers no
            // ordering guarantee between them. The Rust reference's `select!`
            // is explicitly *biased* (hard timeout checked first); this
            // explicit check reproduces that priority deterministically
            // instead of depending on task-completion ordering.
            guard clock.now < hardDeadline else { return .pending }

            let event = await race(mailbox: mailbox, debounceDeadline: debounceDeadline, hardDeadline: hardDeadline, clock: clock)
            switch event {
            case .hardTimeoutFired:
                return .pending
            case .debounceFired, .closed:
                guard clock.now < hardDeadline else { return .pending }
                return .settled(state)
            case let .updates(updates):
                if applyWatchedUpdates(updates, watched: watched, into: &state) {
                    debounceDeadline = clock.now.advanced(by: settleWindow)
                }
            }
        }
    }

    /// Applies `updates` restricted to `watched` uris into `state`, restarting
    /// the debounce window only when at least one of them was actually
    /// watched — extracted from `settleStream`'s `.updates` case to keep that
    /// loop's nesting shallow.
    /// - Parameters:
    ///   - updates: The updates recorded by the mailbox since the last iteration.
    ///   - watched: The uris `settleStream` is waiting on.
    ///   - state: The per-uri diagnostics accumulated so far, updated in place.
    /// - Returns: Whether at least one watched uri was updated (and the debounce window should restart).
    private static func applyWatchedUpdates(
        _ updates: [DiagnosticUpdate],
        watched: Set<DocumentURI>,
        into state: inout [DocumentURI: [Diagnostic]]
    ) -> Bool {
        var sawWatchedUpdate = false
        for update in updates where watched.contains(update.uri) {
            state[update.uri] = update.diagnostics
            sawWatchedUpdate = true
        }
        return sawWatchedUpdate
    }

    /// One iteration's outcome: whichever of "an update arrived", "the
    /// debounce window elapsed", "the hard timeout elapsed", or "the stream
    /// closed" happened first.
    private enum RaceEvent {
        case updates([DiagnosticUpdate])
        case debounceFired
        case hardTimeoutFired
        case closed
    }

    /// Races the mailbox's next update against a fresh `sleep(until:
    /// debounceDeadline)` and a fresh `sleep(until: hardDeadline)`,
    /// cancelling the losers.
    ///
    /// Both sleeps target fixed absolute instants, so re-issuing them fresh
    /// every call (rather than trying to reuse a single long-lived sleep
    /// task across iterations) is correct, not just convenient:
    /// `Clock.sleep(until:)` is cancellation-safe when cancelled within its
    /// own task — unlike awaiting a separate `Task`'s `.value`, which does
    /// not unblock early just because the *awaiting* task was cancelled —
    /// and a fresh call against the same fixed deadline still fires at
    /// exactly that instant regardless of how many prior calls against it
    /// were cancelled by an earlier-arriving update.
    /// - Parameters:
    ///   - mailbox: The mailbox fed by the background stream-drain task.
    ///   - debounceDeadline: The instant the debounce window elapses; recomputed by the caller on every update.
    ///   - hardDeadline: The instant the hard timeout elapses; fixed for the whole `settleStream` call.
    ///   - clock: The clock both instants belong to.
    /// - Returns: The event that won this iteration's race.
    private static func race<C: Clock>(
        mailbox: UpdateMailbox,
        debounceDeadline: C.Instant,
        hardDeadline: C.Instant,
        clock: C
    ) async -> RaceEvent where C.Duration == Duration {
        await withTaskGroup(of: RaceEvent.self) { group in
            group.addTask {
                switch await mailbox.next() {
                case let .updates(updates): .updates(updates)
                case .closed: .closed
                }
            }
            group.addTask {
                try? await clock.sleep(until: hardDeadline, tolerance: nil)
                return .hardTimeoutFired
            }
            group.addTask {
                try? await clock.sleep(until: debounceDeadline, tolerance: nil)
                return .debounceFired
            }
            defer { group.cancelAll() }
            // Exactly 3 tasks were added above, so the group always yields
            // at least one result; `.debounceFired` is an unreachable
            // fallback only `group.next()` returning `nil` could trigger.
            return await group.next() ?? .debounceFired
        }
    }
}
