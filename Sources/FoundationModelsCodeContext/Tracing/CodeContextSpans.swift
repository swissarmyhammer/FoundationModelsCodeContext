import FoundationModelsExtras
import FoundationModelsRanker
import Logging
import Tracing

/// Opens the spans of the package (rules 1, 3, 4 and 8 of the OpenTelemetry design).
///
/// Each span name and each attribute key comes from ``CodeContextTracing``. Each helper selects
/// its tracer with ``CodeContextTracing/tracer(explicit:)``: a caller gives an explicit tracer, or
/// `nil` to read the bootstrapped tracer at the time of the call. With no tracer bootstrapped, the
/// tracer is the no-op tracer, and each helper only runs its body.
///
/// ## The span helpers
///
/// - ``withEnterRecord(_:ofKind:tracer:logger:attributes:metadata:_:)`` is for a call that can
///   suspend for a long time: the index pass, each LSP request and each embed call. It uses
///   `TracedCall` of FoundationModelsExtras, which also writes one "enter" log record when the call
///   starts (rule 8, hang detection). A backend exports a span only when the span ends, thus a call
///   that hangs shows only as its "enter" record.
/// - ``withSpan(_:tracer:attributes:_:)`` is for a short call. It writes no log record.
/// - ``withSearchSpan(_:tracer:limit:resultCount:_:)`` is the one span wrap of each search call:
///   the search, the symbol search and the grep. It uses ``withSpan(_:tracer:attributes:_:)``, and
///   it sets the limit and the result count of the search. A search can embed its query, and that
///   embed call writes its own "enter" record.
///
/// ## No content in a span
///
/// A span of the package holds ids, names, counts and sizes only (rule 4). When the body throws,
/// the helper records only the type name of the error on the span, and sets the status of the span
/// to error. It never records the error itself, because the description of an error can hold
/// content: a `WireError.serverError` holds the message of the language server. The caller gets
/// the original error.
internal enum CodeContextSpans {
    /// Runs `body` in one span, and writes one "enter" log record before `body` starts.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span, from ``CodeContextTracing/SpanName``.
    ///   - kind: The kind of the span. Defaults to `.internal`.
    ///   - tracer: The tracer of the span, or `nil` to read the bootstrapped tracer now.
    ///   - logger: The logger of the "enter" record.
    ///   - attributes: Sets the attributes of the span before the record is written. Ids, names,
    ///     counts and sizes only.
    ///   - metadata: The metadata of the record. Ids, names, counts and sizes only.
    ///   - body: The call. It gets the open span, and it runs on the actor of the caller.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`. The span records only the type name of the error.
    internal nonisolated(nonsending) static func withEnterRecord<Output>(
        _ spanName: String,
        ofKind kind: SpanKind = .internal,
        tracer: (any Tracer)?,
        logger: Logger,
        attributes: (inout SpanAttributes) -> Void = { _ in },
        metadata: Logger.Metadata = [:],
        _ body: nonisolated(nonsending) (any Span) async throws -> Output
    ) async throws -> Output {
        let result = try await TracedCall.run(
            spanName,
            ofKind: kind,
            tracer: CodeContextTracing.tracer(explicit: tracer),
            logger: logger,
            attributes: attributes,
            metadata: metadata
        ) { span in
            await outcome(of: body, in: span)
        }
        return try result.get()
    }

    /// Runs `body` in one span, and writes no log record.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span, from ``CodeContextTracing/SpanName``.
    ///   - tracer: The tracer of the span, or `nil` to read the bootstrapped tracer now.
    ///   - attributes: Sets the attributes of the span before `body` starts. Ids, names, counts and
    ///     sizes only.
    ///   - body: The call. It gets the open span, and it runs on the actor of the caller.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`. The span records only the type name of the error.
    internal nonisolated(nonsending) static func withSpan<Output>(
        _ spanName: String,
        tracer: (any Tracer)?,
        attributes: (inout SpanAttributes) -> Void = { _ in },
        _ body: nonisolated(nonsending) (any Span) async throws -> Output
    ) async throws -> Output {
        let result = await CodeContextTracing.tracer(explicit: tracer).withSpan(spanName) { span in
            span.updateAttributes(attributes)
            return await outcome(of: body, in: span)
        }
        return try result.get()
    }

    /// Runs one search call in one span, and writes no log record. This is the one span wrap of
    /// each search call: the search, the symbol search and the grep.
    ///
    /// The span holds the limit before `body` starts, and the result count after `body` returns.
    /// It never holds the query or the pattern of the search.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span, from ``CodeContextTracing/SpanName``.
    ///   - tracer: The tracer of the span, or `nil` to read the bootstrapped tracer now.
    ///   - limit: The maximum number of results that the caller asks for.
    ///   - resultCount: Gives the number of results in the value of `body`.
    ///   - body: The search call. It runs on the actor of the caller.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`. The span records only the type name of the error, and it
    ///   holds no result count.
    internal nonisolated(nonsending) static func withSearchSpan<Output>(
        _ spanName: String,
        tracer: (any Tracer)?,
        limit: Int,
        resultCount: (Output) -> Int,
        _ body: nonisolated(nonsending) () async throws -> Output
    ) async throws -> Output {
        try await withSpan(
            spanName,
            tracer: tracer,
            attributes: { $0[CodeContextTracing.AttributeKey.searchLimit] = limit },
            { span in
                let output = try await body()
                span.attributes[CodeContextTracing.AttributeKey.searchResultCount] = resultCount(output)
                return output
            }
        )
    }

    /// Embeds `texts` with `embedder` in one ``CodeContextTracing/SpanName/embed`` span, and writes
    /// one "enter" log record before the call.
    ///
    /// The span and the record hold the count of the texts. They never hold the texts.
    ///
    /// `TextEmbedding` declares no vector length. Thus the span gets the dimension after the call,
    /// from the length of the first vector that the call returns. The "enter" record is written
    /// before the call, thus it holds no dimension. A call that throws, or that returns no vector,
    /// gives a span with no dimension.
    ///
    /// - Parameters:
    ///   - texts: The texts to embed.
    ///   - embedder: The embedder that makes the vectors.
    ///   - tracer: The tracer of the span, or `nil` to read the bootstrapped tracer now.
    /// - Returns: The vectors that `embedder` makes, in the order of `texts`.
    /// - Throws: The error of `embedder`. The span records only the type name of the error.
    internal static func embed(_ texts: [String], with embedder: TextEmbedding, tracer: (any Tracer)?) async throws -> [[Float]] {
        try await withEnterRecord(
            CodeContextTracing.SpanName.embed,
            tracer: tracer,
            logger: Log.embedding,
            attributes: { $0[CodeContextTracing.AttributeKey.embeddingInputCount] = texts.count },
            metadata: [CodeContextTracing.MetadataKey.embeddingInputCount: .stringConvertible(texts.count)],
            { span in
                let vectors = try await embedder.embed(texts)
                if let dimension = vectors.first?.count {
                    span.attributes[CodeContextTracing.AttributeKey.embeddingDimension] = dimension
                }
                return vectors
            }
        )
    }

    /// Runs `body`, and gives its value or its error as a result. When `body` throws, the span
    /// records only the type name of the error, and the status of the span is error.
    ///
    /// The helper gives the error as a value and does not throw it, thus the `withSpan` of the
    /// tracer does not record the error itself.
    ///
    /// - Parameters:
    ///   - body: The call.
    ///   - span: The open span of the call.
    /// - Returns: `.success` with the value of `body`, or `.failure` with its error.
    private nonisolated(nonsending) static func outcome<Output>(
        of body: nonisolated(nonsending) (any Span) async throws -> Output,
        in span: any Span
    ) async -> Result<Output, any Error> {
        do {
            return .success(try await body(span))
        } catch {
            span.recordError(SpanErrorType(of: error))
            span.setStatus(SpanStatus(code: .error))
            return .failure(error)
        }
    }
}

/// The error that a span records in place of the error of a call: only the type name of that
/// error.
///
/// Its description is the type name, for example `FoundationModelsCodeContext.WireError`. It never
/// holds the description of the original error, because that description can hold content.
internal struct SpanErrorType: Error, CustomStringConvertible {
    /// The type name of the original error.
    internal let description: String

    /// Makes the error that a span records for `error`.
    /// - Parameter error: The error of the call.
    internal init(of error: any Error) {
        description = String(reflecting: type(of: error))
    }
}
