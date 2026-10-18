import Foundation

/// The result of one batch of `LSPIndexWorker`: which files are now
/// `lsp_indexed = 1`, and which files a failure left dirty.
struct LSPIndexBatchOutcome: Sendable, Equatable {
    /// The workspace-relative paths of the files that are now
    /// `lsp_indexed = 1`. This includes a file that the worker skips.
    var indexedPaths: [String] = []

    /// The workspace-relative paths of the files that a request failure or
    /// a store failure left `lsp_indexed = 0`.
    var failedPaths: [String] = []
}

/// The count of failed attempts of each file in the continuous loop of
/// `LSPIndexWorker`.
///
/// A file that always fails stays dirty, and the dirty-file query gives it
/// again in each batch. Without a limit, such a file is in each batch for
/// ever, and it can fill the full batch. The loop records the outcome of each
/// batch here. When the count of a file gets to `limit`, the loop stops the
/// attempts and marks the file indexed. The count of that file then goes back
/// to zero, thus a later watcher event that makes the file dirty again gives
/// it `limit` new attempts.
struct LSPIndexFailureCounts: Sendable {
    /// The number of failed attempts after which the loop stops the attempts
    /// for a file.
    let limit: Int

    /// The failed attempts of each file, by workspace-relative path. A file
    /// with no failure since its last success has no entry.
    private var countsByPath: [String: Int] = [:]

    /// Creates an empty count.
    /// - Parameter limit: The number of failed attempts after which the loop
    ///   stops the attempts for a file.
    init(limit: Int) {
        self.limit = limit
    }

    /// Records the outcome of one batch.
    ///
    /// A file that is now indexed loses its count. A file that failed gets
    /// one more failure.
    /// - Parameter outcome: The outcome of the batch.
    /// - Returns: The failed files whose count got to `limit`, in batch
    ///   order. Their counts go back to zero.
    mutating func record(_ outcome: LSPIndexBatchOutcome) -> [String] {
        for relativePath in outcome.indexedPaths {
            countsByPath[relativePath] = nil
        }
        for relativePath in outcome.failedPaths {
            countsByPath[relativePath, default: 0] += 1
        }
        let exhaustedPaths = outcome.failedPaths.filter { relativePath in
            countsByPath[relativePath, default: 0] >= limit
        }
        for relativePath in exhaustedPaths {
            countsByPath[relativePath] = nil
        }
        return exhaustedPaths
    }
}

extension LSPIndexWorker {
    /// Stops the attempts for each file in `relativePaths`: writes one
    /// warning for each file and marks it `lsp_indexed = 1`.
    ///
    /// The dirty-file query then does not give the file again, thus it does
    /// not block the other dirty files. A later watcher event makes the file
    /// dirty again.
    /// - Parameters:
    ///   - relativePaths: The files whose failure count got to the limit.
    ///   - store: The workspace's index store to write into.
    static func stopAttempts(for relativePaths: [String], store: Store) async {
        for relativePath in relativePaths {
            _ = await skipFile(
                relativePath: relativePath,
                store: store,
                level: .warning,
                message: "the LSP index worker stops the attempts for a file that failed too many times and marks the file indexed"
            )
        }
    }
}
