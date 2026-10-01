import Foundation
import Logging

/// The failure log of `LSPIndexWorker`: one place that decides whether an
/// error of a request or of a store call is a failure, and at which level
/// the worker writes it.
///
/// A stop of the task is not a failure. `CodeContext.stop()` cancels each LSP
/// index task, and the call that is in flight at that time throws. The
/// worker then writes one debug record, no warning and no error, and the
/// file stays dirty for the next pass.
extension LSPIndexWorker {
    /// Whether `error` comes from the stop of the calling task, not from a
    /// failure of the server or of the store.
    ///
    /// `CodeContext.stop()` cancels each LSP index task. A request that is in
    /// flight then throws `CancellationError`, and a store call (GRDB looks
    /// for cancellation) throws it too. `Store` wraps each error that is not
    /// a `CodeContextError` in `CodeContextError.storage`, thus the type of a
    /// store cancellation is lost. The cancelled state of the task tells it.
    /// - Parameter error: The error of a request or of a store call.
    /// - Returns: `true` when `error` is a `CancellationError` or the calling
    ///   task is cancelled.
    static func isStop(_ error: any Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }

    /// Logs the failure of one request of the worker through
    /// `LspSession.logFailure(of:filePath:error:)`, one time for each
    /// (server, request) pair. A stop of the task (see `isStop(_:)`) is not a
    /// failure: it writes one debug record and no warning.
    /// - Parameters:
    ///   - request: The request that failed.
    ///   - filePath: The workspace-relative path of the file of the request.
    ///   - error: The error of the request.
    ///   - session: The session that sent the request.
    static func logRequestFailure(
        of request: SessionRequest,
        filePath: String,
        error: any Error,
        session: LspSession<Connection>
    ) async {
        guard !isStop(error) else {
            logStop(filePath: filePath, error: error)
            return
        }
        await session.logFailure(of: request, filePath: filePath, error: error)
    }

    /// Logs a store failure of the LSP index of one file as an error. A stop
    /// of the task (see `isStop(_:)`) is not a failure: it writes one debug
    /// record and no error.
    /// - Parameters:
    ///   - message: The fixed message of the error record.
    ///   - filePath: The workspace-relative path of the file.
    ///   - error: The error of the store call.
    static func logStoreFailure(_ message: Logger.Message, filePath: String, error: any Error) {
        guard !isStop(error) else {
            logStop(filePath: filePath, error: error)
            return
        }
        Log.lsp.error(
            message,
            metadata: [
                CodeContextTracing.MetadataKey.filePath: .string(filePath),
                CodeContextTracing.MetadataKey.errorType: Log.errorType(of: error),
            ]
        )
    }

    /// Writes the debug record of a stop of the task during the index of
    /// one file. The file stays `lsp_indexed = 0`, thus the next pass
    /// indexes it again.
    /// - Parameters:
    ///   - filePath: The workspace-relative path of the file.
    ///   - error: The error that the stop caused.
    private static func logStop(filePath: String, error: any Error) {
        Log.lsp.debug(
            "the LSP index task stops before the index of a file is complete; the file stays dirty for the next pass",
            metadata: [
                CodeContextTracing.MetadataKey.filePath: .string(filePath),
                CodeContextTracing.MetadataKey.errorType: Log.errorType(of: error),
            ]
        )
    }
}
