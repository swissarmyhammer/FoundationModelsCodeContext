/// A language server's launch and lifecycle configuration.
///
/// Ports the Rust `builtin/lsp/*.yaml` server specs to a plain Swift value
/// declared directly by the owning `LanguageModule` — no standalone YAML
/// registry (see plan.md "LSP subsystem": "the Rust YAML spec fields become
/// a plain Swift value ... No standalone registry; the supervisor collects
/// specs from `Languages.all`."). Multi-language servers (e.g.
/// `typescript-language-server`, `clangd`) share one `ServerSpec` instance
/// across their modules; the supervisor dedupes daemons by `command`.
public struct ServerSpec: Sendable, Equatable {
    /// The executable to spawn, looked up on `$PATH` (e.g. `"rust-analyzer"`).
    public let command: String

    /// Arguments passed to `command` on launch.
    public let args: [String]

    /// LSP `languageId` values this server handles (e.g. `["rust"]`).
    public let languageIDs: [String]

    /// How long to wait for the `initialize`/`initialized` handshake before
    /// treating startup as failed.
    public let startupTimeout: Duration

    /// How often the supervisor checks that the daemon process is still
    /// alive.
    public let healthCheckInterval: Duration

    /// Human-readable guidance shown when `command` isn't found on `$PATH`.
    public let installHint: String

    /// Creates a server spec.
    ///
    /// - Parameters:
    ///   - command: The executable to spawn, looked up on `$PATH`.
    ///   - args: Arguments passed to `command` on launch. Defaults to none.
    ///   - languageIDs: LSP `languageId` values this server handles.
    ///   - startupTimeout: Handshake timeout. Defaults to 30 seconds, matching
    ///     every `builtin/lsp/*.yaml` spec's `startup_timeout_secs`.
    ///   - healthCheckInterval: Liveness check interval. Defaults to 60
    ///     seconds, matching every `builtin/lsp/*.yaml` spec's
    ///     `health_check_interval_secs`.
    ///   - installHint: Guidance shown when `command` isn't found on `$PATH`.
    public init(
        command: String,
        args: [String] = [],
        languageIDs: [String],
        startupTimeout: Duration = .seconds(30),
        healthCheckInterval: Duration = .seconds(60),
        installHint: String
    ) {
        self.command = command
        self.args = args
        self.languageIDs = languageIDs
        self.startupTimeout = startupTimeout
        self.healthCheckInterval = healthCheckInterval
        self.installHint = installHint
    }
}
