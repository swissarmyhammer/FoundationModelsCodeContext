import Logging

/// The loggers of FoundationModelsCodeContext.
///
/// Each logger is a swift-log `Logger`. Its label comes from
/// `CodeContextTracing.LoggerLabel`, so each label starts with the module
/// prefix `FoundationModelsCodeContext.`. The package bootstraps no logging
/// backend. The host application bootstraps one with
/// `LoggingSystem.bootstrap(_:)`, and it selects where the records go.
///
/// Each member makes a new `Logger` at each read. Thus a logger reads the
/// bootstrapped backend at the time of the log call, and an application that
/// bootstraps its backend after it makes a ``CodeContext`` still gets the
/// records. A `Logger` that a `static let` keeps would keep the backend of the
/// time of its first read.
///
/// ## No content in a log record
///
/// A record has a fixed message. Its metadata holds only names, identifiers,
/// counts, sizes and error type names, under the keys of
/// `CodeContextTracing.MetadataKey`. A record never holds source code, file
/// content, query text, embed input text, LSP wire payload, the standard error
/// text of a language server, the output of an installer or the description of
/// an error. See `CodeContextTracing` for the rule. Do not use the `error:`
/// parameter of a log call: a backend can write the description of the error.
/// Use ``errorType(of:)`` instead.
public enum Log {
    /// The lifecycle of a language server: start, exit, start again,
    /// handshake and install.
    public static var lsp: Logger { Logger(label: CodeContextTracing.LoggerLabel.lsp) }

    /// The JSON-RPC wire messages, at `.trace`.
    ///
    /// A record of this logger holds only the server name, the method name,
    /// the request id, the direction and the byte size of one message. It
    /// never holds the payload, at no log level.
    public static var lspWire: Logger { Logger(label: CodeContextTracing.LoggerLabel.lspWire) }

    /// The index: the walk, the reconcile step and the chunk counts.
    public static var index: Logger { Logger(label: CodeContextTracing.LoggerLabel.index) }

    /// The file system watcher.
    public static var watcher: Logger { Logger(label: CodeContextTracing.LoggerLabel.watcher) }

    /// The embedding of text.
    public static var embedding: Logger { Logger(label: CodeContextTracing.LoggerLabel.embedding) }

    /// The search: BM25, trigram, cosine and RRF fusion.
    public static var search: Logger { Logger(label: CodeContextTracing.LoggerLabel.search) }

    /// The diagnostics and the settle engine.
    public static var diagnostics: Logger { Logger(label: CodeContextTracing.LoggerLabel.diagnostics) }

    /// Gives the metadata value that names the type of an error.
    ///
    /// Put this value under `CodeContextTracing.MetadataKey.errorType`. It is
    /// the full type name, for example
    /// `FoundationModelsCodeContext.CodeContextError`. It is never the
    /// description of the error, because a description can hold content.
    ///
    /// - Parameter error: The error to name.
    /// - Returns: The full name of the dynamic type of `error`.
    internal static func errorType(of error: any Error) -> Logger.MetadataValue {
        .string(String(reflecting: type(of: error)))
    }

    /// Gives the metadata values that name an error without its description.
    ///
    /// The metadata always holds the type name under
    /// `CodeContextTracing.MetadataKey.errorType`. For a `CodeContextError` it
    /// also holds the case name under `CodeContextTracing.MetadataKey.errorCase`,
    /// and for a SQLite failure the SQLite extended result code under
    /// `CodeContextTracing.MetadataKey.databaseStatusCode`.
    ///
    /// - Parameter error: The error to name.
    /// - Returns: The type name, and the case name and the SQLite result code
    ///   when the error has them.
    internal static func errorDetail(of error: any Error) -> Logger.Metadata {
        var metadata: Logger.Metadata = [CodeContextTracing.MetadataKey.errorType: errorType(of: error)]
        guard let error = error as? CodeContextError else {
            return metadata
        }
        metadata[CodeContextTracing.MetadataKey.errorCase] = .string(error.caseName)
        if case .storage(_, let sqliteResultCode?) = error {
            metadata[CodeContextTracing.MetadataKey.databaseStatusCode] = .stringConvertible(sqliteResultCode)
        }
        return metadata
    }

    /// Gives the metadata of a record about a failure of a language server.
    ///
    /// - Parameters:
    ///   - server: The command name of the language server.
    ///   - error: The error of the failure. The metadata holds only its type name.
    /// - Returns: The server name under `CodeContextTracing.MetadataKey.lspServer` and the error
    ///   type name under `CodeContextTracing.MetadataKey.errorType`.
    internal static func serverFailureMetadata(server: String, error: any Error) -> Logger.Metadata {
        [
            CodeContextTracing.MetadataKey.lspServer: .string(server),
            CodeContextTracing.MetadataKey.errorType: errorType(of: error),
        ]
    }
}
