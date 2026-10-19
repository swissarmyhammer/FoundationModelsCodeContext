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
    public let arguments: [String]

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

    /// A machine-actionable installer for `command`, or `nil` for hint-only
    /// behavior.
    ///
    /// When present, the supervisor may run `tool` with `arguments` to
    /// install `command` automatically before falling back to showing
    /// `installHint`. `nil` means today's behavior: no auto-install is
    /// attempted, and only `installHint` is shown.
    public let installer: InstallSpec?

    /// The server-specific options that the client sends as `initializationOptions` in the
    /// `initialize` request, or `nil` to send no `initializationOptions` field.
    ///
    /// The value is opaque to this package: each server documents the options that it
    /// accepts.
    public let initializationOptions: JSONValue?

    /// A machine-actionable installer: an executable plus the arguments that
    /// install a language server's `command`.
    public struct InstallSpec: Sendable, Equatable {
        /// The installer executable, looked up on `$PATH` (e.g. `"npm"`,
        /// `"rustup"`, `"go"`, `"pipx"`, `"brew"`). If `tool` itself is
        /// missing from `$PATH`, auto-install is skipped and the owning
        /// `ServerSpec.installHint` behavior stands.
        public let tool: String

        /// The full argv tail passed to `tool` (e.g.
        /// `["install", "-g", "typescript-language-server", "typescript@6"]`).
        public let arguments: [String]

        /// Well-known bin directories the install lands in that may not be
        /// on `$PATH`, with `~` expansion left to the use site (e.g.
        /// `["~/go/bin"]` for `go install`, `["~/.cargo/bin"]` for
        /// `rustup component add`). Empty when `tool` installs onto `$PATH`
        /// directly (e.g. `npm`, `brew`).
        public let extraSearchDirectories: [String]

        /// Creates an install spec.
        ///
        /// - Parameters:
        ///   - tool: The installer executable, looked up on `$PATH`.
        ///   - arguments: The full argv tail passed to `tool`. Defaults to
        ///     none.
        ///   - extraSearchDirectories: Well-known bin directories the
        ///     install lands in that may not be on `$PATH`. Defaults to
        ///     none.
        public init(
            tool: String,
            arguments: [String] = [],
            extraSearchDirectories: [String] = []
        ) {
            self.tool = tool
            self.arguments = arguments
            self.extraSearchDirectories = extraSearchDirectories
        }
    }

    /// The number of seconds in `defaultStartupTimeout`.
    static let defaultStartupTimeoutSeconds = 30

    /// The default handshake timeout: 30 seconds, the `startup_timeout_secs` of each
    /// `builtin/lsp/*.yaml` spec. `@usableFromInline` because a default argument of the
    /// public `init` names it.
    @usableFromInline static let defaultStartupTimeout: Duration = .seconds(defaultStartupTimeoutSeconds)

    /// The number of seconds in `defaultHealthCheckInterval`.
    static let defaultHealthCheckIntervalSeconds = 60

    /// The default liveness check interval: 60 seconds, the `health_check_interval_secs` of
    /// each `builtin/lsp/*.yaml` spec. `@usableFromInline` because a default argument of the
    /// public `init` names it.
    @usableFromInline static let defaultHealthCheckInterval: Duration = .seconds(defaultHealthCheckIntervalSeconds)

    /// Creates a server spec.
    ///
    /// - Parameters:
    ///   - command: The executable to spawn, looked up on `$PATH`.
    ///   - arguments: Arguments passed to `command` on launch. Defaults to none.
    ///   - languageIDs: LSP `languageId` values this server handles.
    ///   - startupTimeout: Handshake timeout. Defaults to 30 seconds, matching
    ///     every `builtin/lsp/*.yaml` spec's `startup_timeout_secs`.
    ///   - healthCheckInterval: Liveness check interval. Defaults to 60
    ///     seconds, matching every `builtin/lsp/*.yaml` spec's
    ///     `health_check_interval_secs`.
    ///   - installHint: Guidance shown when `command` isn't found on `$PATH`.
    ///   - installer: A machine-actionable installer for `command`. Defaults
    ///     to `nil` (hint-only, exactly today's behavior).
    ///   - initializationOptions: The server-specific options of the `initialize` request.
    ///     Defaults to `nil`: the request has no `initializationOptions` field.
    public init(
        command: String,
        arguments: [String] = [],
        languageIDs: [String],
        startupTimeout: Duration = defaultStartupTimeout,
        healthCheckInterval: Duration = defaultHealthCheckInterval,
        installHint: String,
        installer: InstallSpec? = nil,
        initializationOptions: JSONValue? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.languageIDs = languageIDs
        self.startupTimeout = startupTimeout
        self.healthCheckInterval = healthCheckInterval
        self.installHint = installHint
        self.installer = installer
        self.initializationOptions = initializationOptions
    }
}
