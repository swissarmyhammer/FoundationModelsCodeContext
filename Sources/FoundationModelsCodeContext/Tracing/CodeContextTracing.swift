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
///
/// Two tests prove this rule. Each test puts a marker text in the content,
/// runs the telemetry paths, and fails on each span name and attribute, log
/// message and metadata value, and metric name and dimension that holds the
/// marker:
///
/// - `TelemetryContentSafetyTests` in the unit test target uses fakes. It runs
///   an index pass with embed calls, a watcher batch, a search, a symbol search
///   and a grep, a forced restart of a language server, and requests through an
///   LSP session.
/// - `TelemetryContentSafetyTests` in the `IntegrationTests` package starts a
///   real scripted language server. It sends requests through
///   `ProcessLanguageServerConnection`, and it checks the `lspRequest` spans,
///   the `lsp-wire` records, the standard error records and the
///   `lsp.request.duration` timers.
public enum CodeContextTracing {
    /// The text that each span name, each metric name and each logger label
    /// starts with.
    private static let modulePrefix = "FoundationModelsCodeContext."

    /// The operation name of each span that the package opens.
    public enum SpanName {
        /// One index pass: the reconcile step and the index workers after it.
        public static let indexPass = modulePrefix + "index.pass"

        /// One batch of file events that `Watcher.flushPendingEvents()` sends
        /// to the index.
        public static let watcherBatch = modulePrefix + "watcher.batch"

        /// One JSON-RPC request to a language server.
        public static let lspRequest = modulePrefix + "lsp.request"

        /// One `TextEmbedding.embed(_:)` call.
        public static let embed = modulePrefix + "embed"

        /// One `searchCode` call.
        public static let search = modulePrefix + "search"

        /// One `searchSymbol` call.
        public static let searchSymbol = modulePrefix + "search_symbol"

        /// One `grepCode` call.
        public static let grepCode = modulePrefix + "grep_code"
    }

    /// The key of each attribute that a span of the package carries.
    ///
    /// A metric of the package uses these keys as its dimension names too.
    /// Each value under a key is an identifier, a name, a count or a size.
    public enum AttributeKey {
        /// The command name of the language server, for example
        /// `rust-analyzer`.
        public static let lspServer = "lsp.server"

        /// The JSON-RPC method name of a request, for example
        /// `textDocument/definition`.
        public static let lspMethod = "lsp.method"

        /// The JSON-RPC id of a request.
        public static let lspRequestId = "lsp.request_id"

        /// The size of the encoded request, in bytes.
        public static let lspRequestBytes = "lsp.request_bytes"

        /// The size of the encoded response, in bytes.
        public static let lspResponseBytes = "lsp.response_bytes"

        /// How a request ended, for example `ok`, `error` or `timeout`.
        public static let lspOutcome = "lsp.outcome"

        /// The number of files that an index pass indexed.
        public static let indexFilesIndexed = "index.files_indexed"

        /// The number of files that an index pass removed from the index.
        public static let indexFilesRemoved = "index.files_removed"

        /// The index layer that did the work, for example `treesitter` or
        /// `lsp`.
        public static let indexLayer = "index.layer"

        /// The number of file events in one watcher batch.
        public static let watcherBatchSize = "watcher.batch_size"

        /// The number of strings that one embed call embeds.
        public static let embeddingInputCount = "embedding.input_count"

        /// The length of each vector that one embed call makes. The span gets it from the first
        /// vector that the call returns, not from the embedder: `TextEmbedding` declares no
        /// vector length.
        public static let embeddingDimension = "embedding.dimension"

        /// The number of results that one search gives.
        public static let searchResultCount = "search.result_count"

        /// The maximum number of results that the caller of one search asked
        /// for.
        public static let searchLimit = "search.limit"

        /// Why a language server started again, for example `health`,
        /// `install` or `forced`.
        public static let restartReason = "lsp.restart_reason"

        /// The name of the language module, for example `swift`.
        public static let language = "language"
    }

    /// The name of each metric that the package records.
    public enum MetricName {
        /// The timer that records the duration of each index pass.
        public static let indexDuration = modulePrefix + "index.duration"

        /// The counter that counts the indexed files. Its dimension is
        /// ``AttributeKey/indexLayer``: `treesitter` for the files of the
        /// index passes, `lsp` for the files of the LSP index workers.
        public static let filesIndexed = modulePrefix + "index.files_indexed"

        /// The timer that records the duration of each request to a language
        /// server. Its dimensions are ``AttributeKey/lspMethod``,
        /// ``AttributeKey/lspServer`` and ``AttributeKey/lspOutcome``.
        public static let lspRequestDuration = modulePrefix + "lsp.request.duration"

        /// The counter that counts each start again of a language server. Its
        /// dimensions are ``AttributeKey/lspServer`` and
        /// ``AttributeKey/restartReason``.
        public static let lspServerRestarts = modulePrefix + "lsp.server.restarts"
    }

    /// The key of each metadata value that a log record of the package
    /// carries.
    ///
    /// A key that also names a span attribute has the same text as that
    /// attribute key, so a reader can join a log record to its span. Each value
    /// under a key is an identifier, a name, a count or a size.
    public enum MetadataKey {
        /// The command name of the language server.
        public static let lspServer = AttributeKey.lspServer

        /// The JSON-RPC method name of a request.
        public static let lspMethod = AttributeKey.lspMethod

        /// The JSON-RPC id of a request.
        public static let lspRequestId = AttributeKey.lspRequestId

        /// The direction of a wire message: to the server or from the server.
        public static let lspDirection = "lsp.direction"

        /// The number of the attempt to start a language server.
        public static let lspAttempt = "lsp.attempt"

        /// A size, in bytes. It is never the bytes themselves.
        public static let bytes = "bytes"

        /// A file path relative to the root directory.
        public static let filePath = "file.path"

        /// The type name of an error, for example
        /// `FoundationModelsCodeContext.CodeContextError`. It is never the
        /// description of the error, because a description can hold content.
        public static let errorType = "error.type"

        /// The case name of a `CodeContextError`, for example `storage`. It is
        /// never the associated text of the case, because that text can hold
        /// content.
        public static let errorCase = "error.case"

        /// The SQLite extended result code of a failed database operation, for
        /// example `5` (`SQLITE_BUSY`) or `1811` (`SQLITE_CONSTRAINT_TRIGGER`).
        /// The key is the OpenTelemetry semantic convention for a database
        /// status code.
        public static let databaseStatusCode = "db.response.status_code"

        /// The name of the language module.
        public static let language = AttributeKey.language

        /// The name of one kind of request that an LSP session sends, for
        /// example `prepareCallHierarchy`. One kind can send more than one
        /// JSON-RPC method: `syncOpen` sends `didOpen` or `didChange`.
        public static let lspRequest = "lsp.request"

        /// The JSON-RPC error code in the error response of a language
        /// server, for example `-32601`. It is never the error message of the
        /// server, because a message can hold content.
        public static let lspErrorCode = "lsp.error_code"

        /// The name of the tool that installs a language server, for example
        /// `brew` or `npm`.
        public static let lspInstaller = "lsp.installer"

        /// The exit code of a process that the package ran.
        public static let exitCode = "process.exit_code"

        /// The length of each vector that the embedder makes. The index pass gets it from the
        /// first vector that the embedder returns, not from the embedder: `TextEmbedding`
        /// declares no vector length.
        public static let embeddingDimension = AttributeKey.embeddingDimension

        /// The length of each vector that the index holds from an earlier
        /// embedder.
        public static let embeddingStoredDimension = "embedding.stored_dimension"

        /// The number of strings that one embed call embeds.
        public static let embeddingInputCount = AttributeKey.embeddingInputCount

        /// The number of vectors that one embed call returns.
        public static let embeddingOutputCount = "embedding.output_count"
    }

    /// The label of each logger of the package.
    ///
    /// Each label replaces one category of the unified logging system that
    /// the package used before.
    public enum LoggerLabel {
        /// The lifecycle of a language server: start, stop, start again and
        /// handshake.
        public static let lsp = modulePrefix + "lsp"

        /// The JSON-RPC wire messages. A record of this logger holds only the
        /// method name, the request id, the direction and the byte size, never
        /// the payload.
        public static let lspWire = modulePrefix + "lsp-wire"

        /// The index: the walk, the reconcile step and the chunk counts.
        public static let index = modulePrefix + "index"

        /// The file system watcher.
        public static let watcher = modulePrefix + "watcher"

        /// The embedding of text.
        public static let embedding = modulePrefix + "embedding"

        /// The search.
        public static let search = modulePrefix + "search"

        /// The diagnostics and the settle engine.
        public static let diagnostics = modulePrefix + "diagnostics"
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
    public static func tracer(explicit: (any Tracer)?) -> any Tracer {
        explicit ?? InstrumentationSystem.tracer
    }
}
