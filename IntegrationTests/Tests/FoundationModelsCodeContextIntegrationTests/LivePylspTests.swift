import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Real-`pylsp` end-to-end test of the references fallback: `pylsp` has no
/// call hierarchy, so the callers of a Python function must come from
/// `textDocument/references`. The fixture is the `sample.py` reproduction of
/// the kanban task (`main` calls `helper`), plus a second module whose
/// `caller_two` calls `helper` too.
///
/// This suite lives in the `IntegrationTests` nested package, so a root
/// `swift test` never runs it. Run it with
/// `swift test --package-path IntegrationTests`. The `.enabled(if:)` trait
/// skips the test when `pylsp` is not on `$PATH`.
struct LivePylspTests {
    /// The `sample.py` reproduction of the kanban task: `main` calls `helper`.
    private static let sampleSource = "def helper():\n    return 1\n\n\ndef main():\n    return helper()\n"

    /// A second module whose `caller_two` calls `helper` through an import.
    private static let otherSource = "from sample import helper\n\n\ndef caller_two():\n    x = helper()\n    return x\n"

    /// The `<file>:<line>:<column>` locator of the name `helper` in `sample.py`.
    private static let helperLocator = "sample.py:0:4"

    /// The callers of `helper` that the references fallback must find.
    private static let expectedCallers = ["caller_two", "main"]

    /// Whether `pylsp` resolves on `$PATH`.
    private static var isPylspOnPath: Bool {
        BinaryLookup.isOnPath("pylsp")
    }

    /// Writes the Python fixture: a `pyproject.toml` marker (so the project
    /// detection starts `pylsp`) and the two modules.
    private static func writeFixture(in root: URL) throws {
        try write("[project]\nname = \"sample\"\nversion = \"0.1.0\"\n", to: "pyproject.toml", in: root)
        try write(sampleSource, to: "sample.py", in: root)
        try write(otherSource, to: "other.py", in: root)
    }

    /// The names of the lsp-sourced callers of `helper` in the call graph, sorted.
    private static func lspCallersOfHelper(_ context: CodeContext<ProcessLanguageServerConnection>) async -> [String] {
        guard let graph = try? await context.callGraph(of: helperLocator, direction: .inbound, maxDepth: 1) else {
            return []
        }
        return graph.edges.filter { $0.source == .lsp }.map(\.caller.name).sorted()
    }

    @Test(.enabled(if: LivePylspTests.isPylspOnPath, "pylsp not found on $PATH"))
    func pythonCallersComeFromReferencesBecausePylspHasNoCallHierarchy() async throws {
        try await withTemporaryWorkspace { root in
            try Self.writeFixture(in: root)

            // The context stops on every exit path (see `withLiveContext` in IntegrationSupport.swift).
            let factory = LSPDaemon<ProcessLanguageServerConnection>.processConnectionFactory()
            try await withLiveContext(rootDirectory: root, connectionFactory: factory) { context in
                try await context.start()
                await context.waitForFirstIndexPass()

                // The LSP index layer drains in the background after the first pass.
                var callers: [String] = []
                let indexed = try await poll(budget: .seconds(90), interval: .milliseconds(500)) {
                    callers = await Self.lspCallersOfHelper(context)
                    return callers == Self.expectedCallers
                }
                #expect(indexed, "the call graph never gave the callers of helper from references, got \(callers)")

                let inbound = try await context.inboundCalls(filePath: "sample.py", line: 0, character: 4)
                #expect(inbound.calls.map(\.callerName).sorted() == Self.expectedCallers)

                // The blast radius keeps one entry for each symbol. When the
                // tree-sitter heuristic found the same caller too, the entry can
                // name that source, so this check reads the names only; the
                // call-graph check above proves the lsp-sourced edges.
                let radius = try await context.blastRadius(file: "sample.py", symbol: "helper", maxHops: 1)
                let affected = Set(radius.hops.flatMap(\.symbols).map(\.name))
                #expect(affected == Set(Self.expectedCallers))
            }
        }
    }
}
