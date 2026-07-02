/// The meta-type of a chunked or indexed symbol, independent of language.
///
/// Every `LanguageModule.chunkKinds` maps its grammar's node kinds onto one
/// of these four buckets, which then drives kind-aware ops without
/// re-parsing — see plan.md "The index (SQLite, Rust-derived schema — owned
/// by us)": the `ts_chunks.kind` column is one addition over the Rust
/// schema, and `findDuplicates` compares chunks only within the same
/// meta-type (methods/functions against each other, types against types).
public enum SymbolMetaType: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// A free function, not bound to an enclosing type.
    case function

    /// A function bound to an enclosing type (an instance or static method).
    case method

    /// A type declaration — class, struct, enum, protocol, trait, interface, …
    case type

    /// Any other embeddable node kind that isn't a function, method, or
    /// type declaration (e.g. an `impl` block, a module, a constant).
    case other
}
