import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `ProjectDetector`: the strategy list, a strategy of a caller, and
/// the detection off the Swift cooperative pool. `ProjectDetectionTests` holds
/// the tests of the marker rules of the language modules.
struct ProjectDetectorTests {
    /// The marker file of the test strategy.
    private static let toolVersionsMarker = "mise.toml"

    /// The language name of the test strategy.
    private static let toolVersionsLanguage = "tool-versions"

    @Test
    func theLanguageModuleDetectorHasOneStrategyForEachModuleInRegistryOrder() {
        let languages = ProjectDetector.languageModules.strategies.map(\.language)

        #expect(languages == Languages.all.map { $0.name })
    }

    @Test
    func aDetectorRunsItsStrategyOnEachDirectoryOfTheTree() async throws {
        try await withTemporaryWorkspace { root in
            try write("[tools]\n", to: Self.toolVersionsMarker, in: root)
            try write("[tools]\n", to: "service/\(Self.toolVersionsMarker)", in: root)
            try write("print('a')\n", to: "other/main.py", in: root)
            let detector = ProjectDetector(strategies: [
                MarkerNameStrategy(language: Self.toolVersionsLanguage, markerName: Self.toolVersionsMarker)
            ])

            let projects = try detector.detectProjects(rootDirectory: root)

            #expect(projects.allSatisfy { $0.language == Self.toolVersionsLanguage })
            #expect(
                Set(projects.map(\.directory.standardizedFileURL)) == [
                    root.standardizedFileURL,
                    root.appendingPathComponent("service").standardizedFileURL,
                ])
        }
    }

    @Test
    func theDetectionOffTheCooperativePoolGivesTheProjectsOfTheSynchronousDetection() async throws {
        try await withTemporaryWorkspace { root in
            try write("[package]\nname = \"a\"", to: "Cargo.toml", in: root)
            try write("// swift package", to: "app/Package.swift", in: root)
            let detector = ProjectDetector.languageModules

            let offPool = try await detector.detectProjectsOffCooperativePool(rootDirectory: root)

            #expect(offPool == (try detector.detectProjects(rootDirectory: root)))
            #expect(Set(offPool.map(\.language)) == ["rust", "swift"])
        }
    }
}

/// A test strategy that passes for each directory with one entry of a fixed
/// name.
private struct MarkerNameStrategy: ProjectDetectionStrategy {
    /// The language of the projects that the strategy gives.
    let language: String

    /// The entry name that makes a directory a project.
    let markerName: String

    /// Whether `directory` holds an entry named `markerName`.
    ///
    /// - Parameter directory: The directory to examine.
    /// - Returns: `true` when the directory holds the marker.
    func detects(_ directory: ProjectDirectory) -> Bool {
        directory.entryNames.contains(markerName)
    }
}
