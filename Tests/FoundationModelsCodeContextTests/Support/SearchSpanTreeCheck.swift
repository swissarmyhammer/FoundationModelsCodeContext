import InMemoryTracing
import Testing

@testable import FoundationModelsCodeContext

/// The check of the span tree of one search call that uses a selection model.
///
/// The span tree of a search is the same for a context and for a manager: one search span, and
/// one select span that is its child. The check lives here, so each test that needs it uses this
/// one copy.
enum SearchSpanTreeCheck {
    /// Expects that `tracer` holds one search span and one select span that is its child, and that
    /// the count attributes of both spans match the given counts.
    ///
    /// - Parameters:
    ///   - tracer: The tracer that the search call used.
    ///   - candidateCount: The number of candidates that the selection step got.
    ///   - resultCount: The number of hits that the search call returned.
    ///   - sourceLocation: The place of the call, for the failure report.
    static func expectOneSearchSpanWithOneSelectChild(
        in tracer: InMemoryTracer,
        candidateCount: Int,
        resultCount: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let searchSpans = spans(named: CodeContextTracing.SpanName.search, in: tracer)
        let selectSpans = spans(named: CodeContextTracing.SpanName.select, in: tracer)
        #expect(searchSpans.count == 1, sourceLocation: sourceLocation)
        #expect(selectSpans.count == 1, sourceLocation: sourceLocation)
        let searchSpan = try #require(searchSpans.first, sourceLocation: sourceLocation)
        let selectSpan = try #require(selectSpans.first, sourceLocation: sourceLocation)
        #expect(selectSpan.parentSpanID == searchSpan.spanID, sourceLocation: sourceLocation)
        #expect(
            searchSpan.attributes.get(CodeContextTracing.AttributeKey.searchResultCount) == .int64(Int64(resultCount)),
            sourceLocation: sourceLocation
        )
        #expect(
            selectSpan.attributes.get(CodeContextTracing.AttributeKey.selectionCandidateCount)
                == .int64(Int64(candidateCount)),
            sourceLocation: sourceLocation
        )
        #expect(
            selectSpan.attributes.get(CodeContextTracing.AttributeKey.selectionResultCount) == .int64(Int64(resultCount)),
            sourceLocation: sourceLocation
        )
        #expect(selectSpan.errors.isEmpty, sourceLocation: sourceLocation)
    }

    /// Gives the finished spans of `tracer` that have the name `name`.
    ///
    /// - Parameters:
    ///   - name: The operation name of the spans.
    ///   - tracer: The tracer that holds the spans.
    /// - Returns: The spans, in the order of their end.
    static func spans(named name: String, in tracer: InMemoryTracer) -> [FinishedInMemorySpan] {
        tracer.finishedSpans.filter { $0.operationName == name }
    }
}
