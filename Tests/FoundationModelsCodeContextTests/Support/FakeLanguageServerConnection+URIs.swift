@testable import FoundationModelsCodeContext

extension FakeLanguageServerConnection {
    /// Gives the document URIs of the recorded calls that `uri` matches, in
    /// call order.
    ///
    /// Each test helper gives its own case match as `uri`, for example
    /// `{ if case .didClose(let uri) = $0 { uri } else { nil } }`. Thus the
    /// match of each call case stays visible at the call site, and the
    /// iteration over the recorded calls has one copy only.
    /// - Parameter uri: Gives the document URI of a call of the matched case,
    ///   or `nil` for a call of a different case.
    /// - Returns: The URIs, in call order.
    nonisolated func uris(where uri: (Call) -> DocumentURI?) async -> [DocumentURI] {
        await calls.compactMap(uri)
    }
}
