import Foundation

/// The `CodeContext` operations that the FoundationModels tools call.
///
/// A tool operation calls a `CodeContext` through this protocol, not through
/// the generic actor type. Thus a tool does not need the `Connection` type
/// parameter.
///
/// Each requirement has the same signature as its `CodeContext` method. A
/// protocol requirement cannot have a default argument, so each tool
/// operation gives each optional tool parameter as
/// `value ?? CodeContextDefaults.<name>`.
internal protocol CodeContextOperating: Sendable {
    /// See `CodeContext.detectProjects()`.
    @discardableResult
    func detectProjects() async throws -> [DetectedProject]

    /// See `CodeContext.indexStatus()`.
    func indexStatus() async -> IndexProgress

    /// See `CodeContext.lspStatus()`.
    func lspStatus() async -> [ServerStatus]

    /// See `CodeContext.rebuildIndex(layer:)`.
    @discardableResult
    func rebuildIndex(layer: RebuildLayer) async throws -> RebuildIndexResult

    /// See `CodeContext.getSymbol(query:maxResults:)`.
    func getSymbol(query: String, maxResults: Int) async throws -> GetSymbolResult

    /// See `CodeContext.searchSymbol(query:kind:maxResults:)`.
    func searchSymbol(query: String, kind: SymbolMetaType?, maxResults: Int) async throws -> [SearchSymbolMatch]

    /// See `CodeContext.listSymbols(file:)`.
    func listSymbols(file: String) async throws -> [SymbolLocation]

    /// See `CodeContext.callGraph(of:direction:maxDepth:)`.
    func callGraph(of symbol: String, direction: CallGraphDirection, maxDepth: Int) async throws -> CallGraph

    /// See `CodeContext.blastRadius(file:symbol:maxHops:)`.
    func blastRadius(file: String, symbol: String?, maxHops: Int) async throws -> BlastRadius

    /// See `CodeContext.grepCode(pattern:languages:filePattern:maxResults:)`.
    func grepCode(pattern: String, languages: [String], filePattern: String?, maxResults: Int) async throws -> GrepCodeResult

    /// See `CodeContext.searchCode(query:topK:weights:)`.
    func searchCode(query: String, topK: Int, weights: SearchWeights) async throws -> SearchCodeResult

    /// See `CodeContext.findDuplicates(file:minSimilarity:minChunkBytes:maxPerChunk:)`.
    func findDuplicates(file: String?, minSimilarity: Double, minChunkBytes: Int, maxPerChunk: Int) async throws -> FindDuplicatesResult

    /// See `CodeContext.queryAST(language:query:options:)`.
    func queryAST(language: String, query: String, options: QueryASTOptions) async throws -> QueryASTResult

    /// See `CodeContext.definition(filePath:line:character:includeSource:)`.
    func definition(filePath: String, line: Int, character: Int, includeSource: Bool) async throws -> DefinitionResult

    /// See `CodeContext.typeDefinition(filePath:line:character:includeSource:)`.
    func typeDefinition(filePath: String, line: Int, character: Int, includeSource: Bool) async throws -> DefinitionResult

    /// See `CodeContext.hover(filePath:line:character:)`.
    func hover(filePath: String, line: Int, character: Int) async throws -> HoverResult

    /// See `CodeContext.references(filePath:line:character:includeDeclaration:maxResults:)`.
    func references(filePath: String, line: Int, character: Int, includeDeclaration: Bool, maxResults: Int?) async throws -> ReferencesResult

    /// See `CodeContext.implementations(filePath:line:character:includeSource:maxResults:)`.
    func implementations(filePath: String, line: Int, character: Int, includeSource: Bool, maxResults: Int) async throws -> ImplementationsResult

    /// See `CodeContext.codeActions(filePath:startLine:startCharacter:endLine:endCharacter:diagnostics:only:)`.
    func codeActions(
        filePath: String,
        startLine: Int,
        startCharacter: Int,
        endLine: Int,
        endCharacter: Int,
        diagnostics: [Diagnostic],
        only: [String]?
    ) async throws -> CodeActionsResult

    /// See `CodeContext.renameEdits(filePath:line:character:newName:)`.
    func renameEdits(filePath: String, line: Int, character: Int, newName: String) async throws -> RenameEditsResult

    /// See `CodeContext.inboundCalls(filePath:line:character:)`.
    func inboundCalls(filePath: String, line: Int, character: Int) async throws -> InboundCallsResult

    /// See `CodeContext.workspaceSymbols(query:)`.
    func workspaceSymbols(query: String) async throws -> WorkspaceSymbolsResult

    /// See `CodeContext.diagnostics(scope:severity:includeDependents:settleWindow:hardTimeout:perReportCap:)`.
    func diagnostics(
        scope: DiagnosticsScope,
        severity: DiagnosticSeverity,
        includeDependents: Bool,
        settleWindow: Duration,
        hardTimeout: Duration,
        perReportCap: Int
    ) async throws -> DiagnosticsReport
}

/// `CodeContext` has each method of `CodeContextOperating`, for each
/// `Connection` type.
extension CodeContext: CodeContextOperating {}
