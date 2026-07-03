import Foundation

/// Creates a fresh temporary workspace directory for `body`, removed
/// afterwards regardless of outcome. Shared across the test target by any
/// suite that needs an isolated on-disk root (`ReconcilerTests`,
/// `WalkerTests`, `StoreTests`).
func withTemporaryWorkspace<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeContextKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

/// Writes `content` to `relativePath` under `root`, creating any missing
/// intermediate directories. Shared across the test target by any suite
/// that needs to materialize fixture files (`ReconcilerTests`, `WalkerTests`).
func write(_ content: String, to relativePath: String, in root: URL) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
}
