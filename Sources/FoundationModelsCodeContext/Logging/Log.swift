import os

/// Centralized `os.Logger` categories for FoundationModelsCodeContext.
///
/// All loggers share one subsystem, so `log stream --predicate 'subsystem ==
/// "com.swissarmyhammer.FoundationModelsCodeContext"'` (or Console.app) surfaces every
/// category together — exactly what you want when a language server dies at
/// 2am. Category names mirror the Rust `tracing` targets this package ports
/// from, so log output stays legible when cross-referencing the two
/// implementations during the port.
///
/// `os.Logger` is used directly rather than the `swift-log` facade: the
/// macOS 27 floor (inherited from FoundationModelsRouter) makes this an
/// Apple-only package, so `swift-log`'s cross-platform backend story doesn't
/// apply, and unified logging gives structured, near-zero-cost-when-not-
/// captured logging with built-in privacy redaction for free.
public enum Log {
    /// Shared subsystem identifier for all FoundationModelsCodeContext loggers.
    public static let subsystem = "com.swissarmyhammer.FoundationModelsCodeContext"

    /// Language-server lifecycle: spawn, exit, restart, handshake.
    public static let lsp = Logger(subsystem: subsystem, category: "lsp")

    /// Raw LSP request/response wire traffic, logged at `.debug`.
    public static let lspWire = Logger(subsystem: subsystem, category: "lsp-wire")

    /// Indexing: walk/reconcile/chunk counts.
    public static let index = Logger(subsystem: subsystem, category: "index")

    /// Filesystem watcher events.
    public static let watcher = Logger(subsystem: subsystem, category: "watcher")

    /// Embedding generation.
    public static let embedding = Logger(subsystem: subsystem, category: "embedding")

    /// Search: BM25, trigram, cosine, RRF fusion.
    public static let search = Logger(subsystem: subsystem, category: "search")

    /// Diagnostics: diagnose + settle engine.
    public static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
}
