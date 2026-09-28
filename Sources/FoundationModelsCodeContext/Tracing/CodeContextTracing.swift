import Tracing

/// The telemetry vocabulary of the package: the name of each span, the key of
/// each span attribute, the name of each metric, the key of each log metadata
/// value and the label of each logger. It also has the rule that selects the
/// tracer for a call.
///
/// This is the one location for these names. Write a name here one time, and
/// read it from here everywhere. A name here is part of the observable surface
/// of the package: a dashboard, a query or an alert of a host application can
/// use it. Change a name only as a deliberate break.
///
/// Each span name, each metric name and each logger label starts with the
/// module prefix `FoundationModelsCodeContext.`. Thus a reader can find the
/// telemetry of this package in a trace, a metrics store or a log that also
/// holds the telemetry of the host application.
///
/// The package uses the APIs `swift-distributed-tracing`, `swift-log` and
/// `swift-metrics` only. These are abstractions, not exporters. The package
/// bootstraps no backend. Until a host executable bootstraps a backend, each
/// span, each logger and each metric of the package does nothing, so an
/// application that does not collect telemetry pays nothing.
///
/// ## No content in telemetry
///
/// Do not put content in a span attribute, a log message, a log metadata value
/// or a metric dimension. Content is source code, file content, query text,
/// embed input text and LSP wire payload (a JSON-RPC request or response body,
/// or the standard error text of a language server). Telemetry leaves the
/// process through the backend that the host application bootstraps. The
/// package cannot know where that backend sends the data, so the data must not
/// hold the content of the user.
///
/// These values are safe: identifiers, names, counts and sizes. A file path
/// that is relative to the root directory is a name, so it is safe. A server
/// command name, a JSON-RPC method name, a request id, a byte count and an
/// error type name are safe.
///
/// Before you add a key or a name here, make sure that the value it carries is
/// an identifier, a name, a count or a size.
enum CodeContextTracing {
    /// The text that each span name, each metric name and each logger label
    /// starts with.
    private static let modulePrefix = "FoundationModelsCodeContext."

    /// The operation name of each span that the package opens.
    enum SpanName {
        /// One index pass: the reconcile step and the index workers after it.
        static let indexPass = modulePrefix + "index.pass"

        /// One batch of file events that `Watcher.flushPendingEvents()` sends
        /// to the index.
        static let watcherBatch = modulePrefix + "watcher.batch"

        /// One JSON-RPC request to a language server.
        static let lspRequest = modulePrefix + "lsp.request"

        /// One `TextEmbedding.embed(_:)` call.
        static let embed = modulePrefix + "embed"

        /// One `searchCode` call.
        static let search = modulePrefix + "search"

        /// One `searchSymbol` call.
        static let searchSymbol = modulePrefix + "search_symbol"

        /// One `grepCode` call.
        static let grepCode = modulePrefix + "grep_code"
    }

    /// The key of each attribute that a span of the package carries.
    ///
    /// A metric of the package uses these keys as its dimension names too.
    /// Each value under a key is an identifier, a name, a count or a size.
    enum AttributeKey {
        /// The command name of the language server, for example
        /// `rust-analyzer`.
        static let lspServer = "lsp.server"

        /// The JSON-RPC method name of a request, for example
        /// `textDocument/definition`.
        static let lspMethod = "lsp.method"

        /// The JSON-RPC id of a request.
        static let lspRequestId = "lsp.request_id"

        /// The size of the encoded request, in bytes.
        static let lspRequestBytes = "lsp.request_bytes"

        /// The size of the encoded response, in bytes.
        static let lspResponseBytes = "lsp.response_bytes"

        /// How a request ended, for example `ok`, `error` or `timeout`.
        static let lspOutcome = "lsp.outcome"

        /// The number of files that an index pass indexed.
        static let indexFilesIndexed = "index.files_indexed"

        /// The number of files that an index pass removed from the index.
        static let indexFilesRemoved = "index.files_removed"

        /// The index layer that did the work, for example `treesitter` or
        /// `lsp`.
        static let indexLayer = "index.layer"

        /// The number of file events in one watcher batch.
        static let watcherBatchSize = "watcher.batch_size"

        /// The number of strings that one embed call embeds.
        static let embeddingInputCount = "embedding.input_count"

        /// The length of each vector that one embed call makes.
        static let embeddingDimension = "embedding.dimension"

        /// The number of results that one search gives.
        static let searchResultCount = "search.result_count"

        /// The maximum number of results that the caller of one search asked
        /// for.
        static let searchLimit = "search.limit"

        /// Why a language server started again, for example `health`,
        /// `install` or `forced`.
        static let restartReason = "lsp.restart_reason"

        /// The name of the language module, for example `swift`.
        static let language = "language"
    }

    /// The name of each metric that the package records.
    enum MetricName {
        /// The timer that records the duration of each index pass.
        static let indexDuration = modulePrefix + "index.duration"

        /// The counter that counts the files that the index passes index.
        static let filesIndexed = modulePrefix + "index.files_indexed"

        /// The timer that records the duration of each request to a language
        /// server. Its dimensions are ``AttributeKey/lspMethod`` and
        /// ``AttributeKey/lspServer``.
        static let lspRequestDuration = modulePrefix + "lsp.request.duration"

        /// The counter that counts each start again of a language server. Its
        /// dimension is ``AttributeKey/lspServer``.
        static let lspServerRestarts = modulePrefix + "lsp.server.restarts"
    }

    /// The key of each metadata value that a log record of the package
    /// carries.
    ///
    /// A key that also names a span attribute has the same text as that
    /// attribute key, so a reader can join a log record to its span. Each value
    /// under a key is an identifier, a name, a count or a size.
    enum MetadataKey {
        /// The command name of the language server.
        static let lspServer = AttributeKey.lspServer

        /// The JSON-RPC method name of a request.
        static let lspMethod = AttributeKey.lspMethod

        /// The JSON-RPC id of a request.
        static let lspRequestId = AttributeKey.lspRequestId

        /// The direction of a wire message: to the server or from the server.
        static let lspDirection = "lsp.direction"

        /// The number of the attempt to start a language server.
        static let lspAttempt = "lsp.attempt"

        /// A size, in bytes. It is never the bytes themselves.
        static let bytes = "bytes"

        /// A file path relative to the root directory.
        static let filePath = "file.path"

        /// The type name of an error, for example
        /// `FoundationModelsCodeContext.CodeContextError`. It is never the
        /// description of the error, because a description can hold content.
        static let errorType = "error.type"

        /// The name of the language module.
        static let language = AttributeKey.language
    }

    /// The label of each logger of the package.
    ///
    /// Each label replaces one category of the unified logging system that
    /// the package used before.
    enum LoggerLabel {
        /// The lifecycle of a language server: start, stop, start again and
        /// handshake.
        static let lsp = modulePrefix + "lsp"

        /// The JSON-RPC wire messages. A record of this logger holds only the
        /// method name, the request id, the direction and the byte size, never
        /// the payload.
        static let lspWire = modulePrefix + "lsp-wire"

        /// The index: the walk, the reconcile step and the chunk counts.
        static let index = modulePrefix + "index"

        /// The file system watcher.
        static let watcher = modulePrefix + "watcher"

        /// The embedding of text.
        static let embedding = modulePrefix + "embedding"

        /// The search.
        static let search = modulePrefix + "search"

        /// The diagnostics and the settle engine.
        static let diagnostics = modulePrefix + "diagnostics"
    }

    /// Gives the tracer that a call opens its span through.
    ///
    /// `nil` makes the package read the bootstrapped tracer late, at the time
    /// of the call. Thus an application that bootstraps a tracing backend
    /// after it makes a ``CodeContext`` still gets its spans.
    ///
    /// - Parameter explicit: The tracer that the caller gave, or `nil` to read
    ///   the bootstrapped tracer now.
    /// - Returns: `explicit` when it is set, else `InstrumentationSystem.tracer`.
    static func tracer(explicit: (any Tracer)?) -> any Tracer {
        explicit ?? InstrumentationSystem.tracer
    }
}
