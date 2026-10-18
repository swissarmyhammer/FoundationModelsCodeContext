import Foundation

/// The paths in the package that the tests read, from the path of this file.
///
/// Each path is absolute, so a test does not depend on the working directory
/// of `swift test`.
enum PackagePaths {
    /// The number of path components from this file to the root of the package.
    ///
    /// This file is at `Tests/FoundationModelsCodeContextTests/Support/PackagePaths.swift`.
    private static let packageRootDepth = 4

    /// The root directory of the package.
    static let packageRoot: URL = {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<packageRootDepth {
            directory.deleteLastPathComponent()
        }
        return directory
    }()

    /// The directory of the library source files.
    static let librarySources = packageRoot.appending(path: "Sources/FoundationModelsCodeContext")

    /// The directory of the JSON fixtures of the tests. `Package.swift`
    /// excludes it from the test target, thus the tests read it from the disk.
    static let testGoldens = packageRoot.appending(path: "Tests/FoundationModelsCodeContextTests/Goldens")
}
