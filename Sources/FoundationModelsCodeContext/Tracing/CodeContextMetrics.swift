import Metrics

/// Records the metrics of the package through the `swift-metrics` API.
///
/// The package records four metrics. Their names are in ``CodeContextTracing/MetricName``, and
/// their dimension names are in ``CodeContextTracing/AttributeKey``:
///
/// - ``CodeContextTracing/MetricName/indexDuration``: a timer that gets one value for each
///   complete index pass.
/// - ``CodeContextTracing/MetricName/filesIndexed``: a counter of the indexed files, with the
///   dimension ``CodeContextTracing/AttributeKey/indexLayer``. The index pass adds its files under
///   `treesitter`. The LSP index worker indexes files in its own loop, not in the index pass, so it
///   adds its files under `lsp` after each batch.
/// - ``CodeContextTracing/MetricName/lspRequestDuration``: a timer that gets one value for each
///   JSON-RPC request, with the dimensions ``CodeContextTracing/AttributeKey/lspMethod``,
///   ``CodeContextTracing/AttributeKey/lspServer`` and ``CodeContextTracing/AttributeKey/lspOutcome``.
/// - ``CodeContextTracing/MetricName/lspServerRestarts``: a counter of the restarts of a language
///   server, with the dimensions ``CodeContextTracing/AttributeKey/lspServer`` and
///   ``CodeContextTracing/AttributeKey/restartReason``.
///
/// ## The metrics factory
///
/// Each value of this type holds an optional explicit `MetricsFactory`. The production code uses
/// the default value, which holds no factory: each record then reads `MetricsSystem.factory` at the
/// time of the record. Thus an application that bootstraps its metrics backend after it makes a
/// ``CodeContext`` still gets the metrics, the same rule as ``CodeContextTracing/tracer(explicit:)``.
/// A test gives its own factory, for example `TestMetrics`, so tests that run in parallel share no
/// global state and do not bootstrap the global system.
///
/// ## No content in a dimension
///
/// Each dimension value is a name from a small, fixed set: a JSON-RPC method name, the name of a
/// language server, an outcome, a layer or a reason. No dimension value is file content, a query
/// or an LSP payload. The server dimension is the last path component of the server command, so a
/// command that is an absolute path puts no folder name of the user into a metric.
internal struct CodeContextMetrics: Sendable {
    /// How a JSON-RPC request to a language server ended. The raw value is the value of the
    /// dimension ``CodeContextTracing/AttributeKey/lspOutcome``.
    internal enum LSPRequestOutcome: String, Sendable {
        /// The server sent a response that is not an error, and the response decoded.
        case ok

        /// The request failed for a reason that is not a timeout: the server sent an error
        /// response, the response did not decode, or the connection was not usable.
        case error

        /// No response came before the request timeout.
        case timeout

        /// Gives the outcome of a request that threw `error`.
        /// - Parameter error: The error that the request threw.
        internal init(classifying error: any Error) {
            guard case CodeContextError.timeout = error else {
                self = .error
                return
            }
            self = .timeout
        }
    }

    /// Why a language server started again. The raw value is the value of the dimension
    /// ``CodeContextTracing/AttributeKey/restartReason``.
    internal enum RestartReason: String, Sendable {
        /// A health check found that the server process stopped, and the daemon starts it again
        /// after the backoff delay.
        case health

        /// An automatic install of the server binary is complete, and the daemon starts the
        /// server again.
        case install

        /// A caller asked for a restart.
        case forced
    }

    /// The factory that the caller gave, or `nil` to read `MetricsSystem.factory` at each record.
    private let explicitFactory: (any MetricsFactory)?

    /// Makes a value that records into `factory`.
    /// - Parameter factory: The factory to record into, or `nil` to read `MetricsSystem.factory`
    ///   at the time of each record. Defaults to `nil`.
    internal init(factory: (any MetricsFactory)? = nil) {
        explicitFactory = factory
    }

    /// The factory of the next record.
    private var factory: any MetricsFactory {
        explicitFactory ?? MetricsSystem.factory
    }

    /// Records the duration of one complete index pass.
    /// - Parameter duration: The time that the pass took.
    internal func recordIndexPass(duration: Duration) {
        makeTimer(label: CodeContextTracing.MetricName.indexDuration, dimensions: []).record(duration: duration)
    }

    /// Adds `count` to the counter of the files that `layer` indexed.
    /// - Parameters:
    ///   - count: The number of files that the layer indexed.
    ///   - layer: The index layer that indexed the files.
    internal func addFilesIndexed(_ count: Int, layer: IndexLayer) {
        Counter(
            label: CodeContextTracing.MetricName.filesIndexed,
            dimensions: [(CodeContextTracing.AttributeKey.indexLayer, Self.dimensionValue(of: layer))],
            factory: factory
        )
        .increment(by: count)
    }

    /// Records the duration of one JSON-RPC request to a language server.
    /// - Parameters:
    ///   - duration: The time from the send of the request to the decode of its response.
    ///   - method: The JSON-RPC method name of the request.
    ///   - server: The command of the language server. The dimension holds only its last path
    ///     component.
    ///   - outcome: How the request ended.
    internal func recordLSPRequest(duration: Duration, method: String, server: String, outcome: LSPRequestOutcome) {
        let dimensions = [
            (CodeContextTracing.AttributeKey.lspMethod, method),
            (CodeContextTracing.AttributeKey.lspServer, Self.serverName(ofCommand: server)),
            (CodeContextTracing.AttributeKey.lspOutcome, outcome.rawValue),
        ]
        makeTimer(label: CodeContextTracing.MetricName.lspRequestDuration, dimensions: dimensions).record(duration: duration)
    }

    /// Adds 1 to the restart counter of a language server.
    /// - Parameters:
    ///   - server: The command of the language server. The dimension holds only its last path
    ///     component.
    ///   - reason: Why the server starts again.
    internal func addServerRestart(server: String, reason: RestartReason) {
        Counter(
            label: CodeContextTracing.MetricName.lspServerRestarts,
            dimensions: [
                (CodeContextTracing.AttributeKey.lspServer, Self.serverName(ofCommand: server)),
                (CodeContextTracing.AttributeKey.restartReason, reason.rawValue),
            ],
            factory: factory
        )
        .increment()
    }

    /// Makes a timer that a backend shows in seconds.
    /// - Parameters:
    ///   - label: The metric name of the timer.
    ///   - dimensions: The dimensions of the timer.
    /// - Returns: The timer.
    private func makeTimer(label: String, dimensions: [(String, String)]) -> Timer {
        Timer(label: label, dimensions: dimensions, preferredDisplayUnit: .seconds, factory: factory)
    }

    /// Gives the name of a language server for a dimension: the last path component of its
    /// command.
    /// - Parameter command: The command of the server, a bare name or an absolute path.
    /// - Returns: The text after the last `/` of `command`, or `command` when it holds no `/`.
    private static func serverName(ofCommand command: String) -> String {
        command.split(separator: "/").last.map(String.init) ?? command
    }

    /// Gives the value of the dimension ``CodeContextTracing/AttributeKey/indexLayer`` for
    /// `layer`.
    /// - Parameter layer: The index layer.
    /// - Returns: The dimension value of the layer.
    private static func dimensionValue(of layer: IndexLayer) -> String {
        switch layer {
        case .treeSitter:
            "treesitter"
        case .lsp:
            "lsp"
        case .embedding:
            "embedding"
        }
    }
}
