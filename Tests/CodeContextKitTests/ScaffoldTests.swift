import Testing

@testable import CodeContextKit

/// Smoke tests proving the package scaffold itself is wired correctly:
/// the target compiles, `Log`'s subsystem constant is right, and every
/// `CodeContextError` case constructs.
struct ScaffoldTests {
    @Test
    func logSubsystemIsCorrect() {
        #expect(Log.subsystem == "com.swissarmyhammer.CodeContextKit")
    }

    @Test
    func codeContextErrorCasesConstruct() {
        let errors: [CodeContextError] = [
            .binaryNotFound(command: "rust-analyzer", installHint: "brew install rust-analyzer"),
            .spawnFailed("posix_spawn failed"),
            .handshakeFailed("no response to initialize"),
            .timeout(.seconds(30)),
            .notRunning,
            .storage("failed to open kit.db"),
            .embedding("router unavailable"),
        ]

        #expect(errors.count == 7)
    }
}
