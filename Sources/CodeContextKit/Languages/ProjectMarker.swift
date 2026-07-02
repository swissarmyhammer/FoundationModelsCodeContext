/// A marker file (or glob pattern) that identifies a project of a
/// `LanguageModule`'s type, ported from `swissarmyhammer-project-detection`'s
/// `PROJECT_TYPE_SPECS` table.
///
/// A directory matches a `.fileName` marker when the exact file exists, and
/// a `.glob` marker when any entry's name matches the pattern (currently
/// only leading-`*` suffix patterns are used, e.g. `*.xcodeproj`, mirroring
/// `find_wildcard_match` in the Rust crate's `detect.rs`).
public enum ProjectMarker: Sendable, Equatable, Hashable {
    /// An exact file name, e.g. `"Cargo.toml"`.
    case fileName(String)

    /// A glob pattern matched against directory entries, e.g. `"*.xcodeproj"`.
    case glob(String)
}
