import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsCodeContext

/// Tests for the telemetry vocabulary of the package, `CodeContextTracing`.
///
/// Each list below names every member of one group by hand. A new member that
/// is not in its list is not checked, so add each new member to its list.
struct CodeContextTracingTests {
    /// The prefix that each span name, metric name and logger label starts with.
    private static let modulePrefix = "FoundationModelsCodeContext."

    /// The name of the span that the tracer tests open. It is not a name of the vocabulary.
    private static let probeSpanName = "probe"

    /// Every span name.
    private static let spanNames = [
        CodeContextTracing.SpanName.indexPass,
        CodeContextTracing.SpanName.watcherBatch,
        CodeContextTracing.SpanName.lspRequest,
        CodeContextTracing.SpanName.embed,
        CodeContextTracing.SpanName.search,
        CodeContextTracing.SpanName.searchSymbol,
        CodeContextTracing.SpanName.grepCode,
    ]

    /// Every attribute key.
    private static let attributeKeys = [
        CodeContextTracing.AttributeKey.lspServer,
        CodeContextTracing.AttributeKey.lspMethod,
        CodeContextTracing.AttributeKey.lspRequestId,
        CodeContextTracing.AttributeKey.lspRequestBytes,
        CodeContextTracing.AttributeKey.lspResponseBytes,
        CodeContextTracing.AttributeKey.lspOutcome,
        CodeContextTracing.AttributeKey.indexFilesIndexed,
        CodeContextTracing.AttributeKey.indexFilesRemoved,
        CodeContextTracing.AttributeKey.indexLayer,
        CodeContextTracing.AttributeKey.watcherBatchSize,
        CodeContextTracing.AttributeKey.embeddingInputCount,
        CodeContextTracing.AttributeKey.embeddingDimension,
        CodeContextTracing.AttributeKey.searchResultCount,
        CodeContextTracing.AttributeKey.searchLimit,
        CodeContextTracing.AttributeKey.restartReason,
        CodeContextTracing.AttributeKey.language,
    ]

    /// Every metric name.
    private static let metricNames = [
        CodeContextTracing.MetricName.indexDuration,
        CodeContextTracing.MetricName.filesIndexed,
        CodeContextTracing.MetricName.lspRequestDuration,
        CodeContextTracing.MetricName.lspServerRestarts,
    ]

    /// Every log metadata key.
    private static let metadataKeys = [
        CodeContextTracing.MetadataKey.lspServer,
        CodeContextTracing.MetadataKey.lspMethod,
        CodeContextTracing.MetadataKey.lspRequestId,
        CodeContextTracing.MetadataKey.lspDirection,
        CodeContextTracing.MetadataKey.lspAttempt,
        CodeContextTracing.MetadataKey.bytes,
        CodeContextTracing.MetadataKey.filePath,
        CodeContextTracing.MetadataKey.errorType,
        CodeContextTracing.MetadataKey.language,
    ]

    /// Every logger label.
    private static let loggerLabels = [
        CodeContextTracing.LoggerLabel.lsp,
        CodeContextTracing.LoggerLabel.lspWire,
        CodeContextTracing.LoggerLabel.index,
        CodeContextTracing.LoggerLabel.watcher,
        CodeContextTracing.LoggerLabel.embedding,
        CodeContextTracing.LoggerLabel.search,
        CodeContextTracing.LoggerLabel.diagnostics,
    ]

    /// The groups whose names must start with the module prefix.
    private static let prefixedGroups = [
        ("SpanName", spanNames),
        ("MetricName", metricNames),
        ("LoggerLabel", loggerLabels),
    ]

    /// Every group of names in the vocabulary.
    private static let allGroups =
        prefixedGroups + [
            ("AttributeKey", attributeKeys),
            ("MetadataKey", metadataKeys),
        ]

    @Test(arguments: prefixedGroups)
    func everyNameInThePrefixedGroupsStartsWithTheModulePrefix(group: String, names: [String]) {
        for name in names {
            #expect(name.hasPrefix(Self.modulePrefix), "\(group) name \(name) does not start with the module prefix")
        }
    }

    @Test(arguments: prefixedGroups)
    func everyNameInThePrefixedGroupsHasTextAfterTheModulePrefix(group: String, names: [String]) {
        for name in names {
            #expect(name.count > Self.modulePrefix.count, "\(group) name \(name) is only the module prefix")
        }
    }

    @Test(arguments: allGroups)
    func theNamesInEachGroupAreUnique(group: String, names: [String]) {
        #expect(Set(names).count == names.count, "\(group) has two equal names: \(names)")
    }

    @Test(arguments: allGroups)
    func noNameInAGroupIsEmpty(group: String, names: [String]) {
        #expect(names.allSatisfy { !$0.isEmpty }, "\(group) has an empty name")
    }

    @Test
    func theLoggerLabelsReplaceTheUnifiedLoggingCategories() {
        #expect(
            Self.loggerLabels == [
                "FoundationModelsCodeContext.lsp",
                "FoundationModelsCodeContext.lsp-wire",
                "FoundationModelsCodeContext.index",
                "FoundationModelsCodeContext.watcher",
                "FoundationModelsCodeContext.embedding",
                "FoundationModelsCodeContext.search",
                "FoundationModelsCodeContext.diagnostics",
            ])
    }

    @Test
    func theMetadataKeysForTheLanguageServerAreTheSpanAttributeKeys() {
        #expect(CodeContextTracing.MetadataKey.lspServer == CodeContextTracing.AttributeKey.lspServer)
        #expect(CodeContextTracing.MetadataKey.lspMethod == CodeContextTracing.AttributeKey.lspMethod)
        #expect(CodeContextTracing.MetadataKey.lspRequestId == CodeContextTracing.AttributeKey.lspRequestId)
        #expect(CodeContextTracing.MetadataKey.language == CodeContextTracing.AttributeKey.language)
    }

    @Test
    func tracerGivesTheExplicitTracerWhenOneIsSet() {
        let explicit = InMemoryTracer()

        CodeContextTracing.tracer(explicit: explicit).withSpan(Self.probeSpanName) { _ in }

        #expect(explicit.finishedSpans.map(\.operationName) == [Self.probeSpanName])
    }

    @Test
    func tracerGivesTheBootstrappedTracerWhenNoExplicitTracerIsSet() {
        let tracer = CodeContextTracing.tracer(explicit: nil)

        #expect(type(of: tracer) == type(of: InstrumentationSystem.tracer))
    }
}
