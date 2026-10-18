import Foundation

@testable import FoundationModelsCodeContext

extension FakeLanguageServerConnection {
    /// Gives the document URIs of the recorded calls that `uri` matches, in
    /// call order.
    ///
    /// The named helpers below give the case match of each call case. Use
    /// them first. Use this function directly only for a call case that has
    /// no named helper, for example
    /// `{ if case .documentSymbols(let uri) = $0 { uri } else { nil } }`.
    /// Thus the iteration over the recorded calls has one copy only.
    /// - Parameter uri: Gives the document URI of a call of the matched case,
    ///   or `nil` for a call of a different case.
    /// - Returns: The URIs, in call order.
    nonisolated func uris(where uri: (Call) -> DocumentURI?) async -> [DocumentURI] {
        await calls.compactMap(uri)
    }

    /// Gives the document URIs that the connection got a `didOpen` for.
    /// - Returns: The URIs, in call order.
    nonisolated func openedURIs() async -> [DocumentURI] {
        await uris { if case .didOpen(let uri, _, _, _) = $0 { uri } else { nil } }
    }

    /// Gives the file paths of the documents that the connection got a
    /// `didOpen` for. A URI that is not a valid URL gives no path.
    /// - Returns: The file paths, in call order.
    nonisolated func openedPaths() async -> [String] {
        await openedURIs().compactMap { URL(string: $0.value)?.path }
    }

    /// Gives the document URIs that the connection got a `didClose` for.
    /// - Returns: The URIs, in call order.
    nonisolated func closedURIs() async -> [DocumentURI] {
        await uris { if case .didClose(let uri) = $0 { uri } else { nil } }
    }

    /// Gives the document URIs that the connection got a pull-diagnostics
    /// request for.
    /// - Returns: The URIs, in call order.
    nonisolated func pulledURIs() async -> [DocumentURI] {
        await uris { if case .pullDiagnostics(let uri) = $0 { uri } else { nil } }
    }
}
