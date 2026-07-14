import Foundation

/// One diagnostic reported against a file, flattened out of an LSP
/// `Diagnostic` into the shape a `DiagnosticsReport` carries.
///
/// Port of `swissarmyhammer-diagnostics`'s `record::DiagnosticRecord`. The
/// Rust reference wraps `lsp_types::Range` in its own `Range` newtype purely
/// so `record.rs` doesn't depend on the `lsp_types` crate directly; this
/// Swift port reuses `LSPRange` (already `Codable`/`Sendable`/`Equatable` in
/// this same module — see `LSPTypes.swift`) rather than introducing an
/// equivalent wrapper with nothing left to convert from.
struct DiagnosticRecord: Sendable, Equatable {
    /// The file this diagnostic applies to, relative to the workspace root.
    let path: String

    /// The span within `path` this diagnostic applies to.
    let range: LSPRange

    /// The diagnostic's severity.
    let severity: DiagnosticSeverity

    /// The human-readable diagnostic message.
    let message: String

    /// The server's diagnostic code (e.g. `"E0308"`), if any.
    let code: String?

    /// The tool that produced this diagnostic (e.g. `"rustc"`), if any.
    let source: String?

    /// The symbol enclosing this diagnostic's range, if known.
    ///
    /// Always `nil` from `from(diagnostic:path:)` — ports the Rust
    /// reference's `record::map`, which leaves this to be filled in by an
    /// enriching consumer it doesn't itself provide. No such enrichment step
    /// exists in this port (yet), so this field is carried for shape parity
    /// with the Rust reference and always `nil` today.
    let containingSymbol: String?

    /// Creates a diagnostic record.
    /// - Parameters:
    ///   - path: The file this diagnostic applies to, relative to the workspace root.
    ///   - range: The span within `path` this diagnostic applies to.
    ///   - severity: The diagnostic's severity.
    ///   - message: The human-readable diagnostic message.
    ///   - code: The server's diagnostic code, if any. Defaults to `nil`.
    ///   - source: The tool that produced this diagnostic, if any. Defaults to `nil`.
    ///   - containingSymbol: The symbol enclosing this diagnostic's range, if known. Defaults to `nil`.
    init(
        path: String,
        range: LSPRange,
        severity: DiagnosticSeverity,
        message: String,
        code: String? = nil,
        source: String? = nil,
        containingSymbol: String? = nil
    ) {
        self.path = path
        self.range = range
        self.severity = severity
        self.message = message
        self.code = code
        self.source = source
        self.containingSymbol = containingSymbol
    }

    /// Maps a wire-format `Diagnostic` to a `DiagnosticRecord` against `path`.
    ///
    /// Pure and total: every `Diagnostic` field already has the lenient
    /// decoding `Diagnostic.init(from:)` applies (a missing/unrecognized
    /// severity already defaulted to `.hint` before this is ever called), so
    /// this mapping never needs its own fallback logic.
    /// - Parameters:
    ///   - diagnostic: The diagnostic to map.
    ///   - path: The file `diagnostic` applies to, relative to the workspace root.
    /// - Returns: The mapped record, with `containingSymbol` always `nil`.
    static func from(diagnostic: Diagnostic, path: String) -> DiagnosticRecord {
        DiagnosticRecord(
            path: path,
            range: diagnostic.range,
            severity: diagnostic.severity,
            message: diagnostic.message,
            code: diagnostic.code,
            source: diagnostic.source,
            containingSymbol: nil
        )
    }
}

/// Error/warning counts summarizing a `DiagnosticsReport`'s records.
///
/// Port of `swissarmyhammer-diagnostics`'s `record::Counts` — deliberately
/// counts only `.error`/`.warning`, matching the Rust reference and this
/// task's "broken" definition (`errors + warnings > 0`) used to decide
/// whether a dependent folds into a report.
struct Counts: Sendable, Equatable {
    /// The number of `.error`-severity records.
    let errors: Int

    /// The number of `.warning`-severity records.
    let warnings: Int

    /// Counts `records`' `.error`/`.warning` severities; `.information`/`.hint` are ignored.
    /// - Parameter records: The records to count.
    /// - Returns: The computed counts.
    static func from(records: [DiagnosticRecord]) -> Counts {
        var errors = 0
        var warnings = 0
        for record in records {
            switch record.severity {
            case .error: errors += 1
            case .warning: warnings += 1
            case .information, .hint: break
            }
        }
        return Counts(errors: errors, warnings: warnings)
    }
}

/// The result of a `DiagnosticsOps.diagnostics(...)` call: every record found
/// (targets first, then folded-in broken dependents), their error/warning
/// counts, and whether the report reflects a fully-settled answer.
///
/// Port of `swissarmyhammer-diagnostics`'s `record::DiagnosticsReport`,
/// extended with the `pending` flag `diagnose.rs`'s `DiagnoseOutcome` carries
/// alongside the report in the Rust reference — folded directly into this
/// type here rather than kept as a separate wrapper, since this Swift port
/// has exactly one public entry point (`DiagnosticsOps.diagnostics(...)`)
/// that always wants both together.
public struct DiagnosticsReport: Sendable, Equatable {
    /// Every diagnostic record in this report, targets first (in query
    /// order), then folded-in broken dependents (ranked errors-then-warnings),
    /// truncated to the per-report cap.
    let records: [DiagnosticRecord]

    /// Error/warning counts across `records`.
    let counts: Counts

    /// `true` when the report may be incomplete: the settle engine hit its
    /// hard timeout before quiescing, or the language server is running but
    /// not yet ready to answer.
    let pending: Bool

    /// Creates a report, deriving `counts` from `records`.
    /// - Parameters:
    ///   - records: Every diagnostic record in this report.
    ///   - pending: Whether the report may be incomplete.
    init(records: [DiagnosticRecord], pending: Bool) {
        self.records = records
        counts = Counts.from(records: records)
        self.pending = pending
    }
}
