/// Project marker lists shared by more than one `LanguageModule`.
///
/// `swissarmyhammer-project-detection`'s `PROJECT_TYPE_SPECS` table doesn't
/// distinguish TypeScript, TSX, and plain JavaScript from Node.js in
/// general: all three match on the same `package.json` marker. Declaring
/// that marker list once here, rather than three copies, keeps the same
/// single-source-of-truth guarantee for project-marker data that
/// `SharedServerSpecs` gives the LSP server specs.
enum SharedProjectMarkers {
    /// The `package.json` marker shared by the TypeScript, TSX, and
    /// JavaScript modules.
    static let nodeJs: [ProjectMarker] = [
        .fileName("package.json")
    ]

    /// The `CMakeLists.txt`/`Makefile` markers shared by the C and C++
    /// modules.
    ///
    /// `swissarmyhammer-project-detection`'s `PROJECT_TYPE_SPECS` table
    /// doesn't distinguish C from C++ for either build system marker.
    static let cmakeOrMakefile: [ProjectMarker] = [
        .fileName("CMakeLists.txt"),
        .fileName("Makefile"),
    ]
}
