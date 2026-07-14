import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `ProjectDetection`: marker matching driven by `Languages.all`,
/// polyglot monorepo discovery, multi-type single-directory detection,
/// dedupe-by-command server specs, and gitignore-aware exclusion via the
/// shared `Walker` — port of `swissarmyhammer-project-detection`'s
/// `detect.rs` test suite, scoped to this task's `DetectedProject(language,
/// directory)` result shape (no workspace-info parsing).
struct ProjectDetectionTests {
    @Test
    func detectsSingleRustProject() async throws {
        try await withTemporaryWorkspace { root in
            try write("[package]\nname = \"a\"", to: "Cargo.toml", in: root)

            let projects = try ProjectDetection.detectProjects(rootDirectory: root)

            #expect(projects.count == 1)
            #expect(projects[0].language == "rust")
            #expect(projects[0].directory.standardizedFileURL == root.standardizedFileURL)
        }
    }

    @Test
    func detectsPolyglotMonorepoWithCorrectDirectories() async throws {
        try await withTemporaryWorkspace { root in
            try write("// swift package", to: "Package.swift", in: root)
            try write("[package]\nname = \"backend\"", to: "backend/Cargo.toml", in: root)
            try write("{\"name\": \"web\"}", to: "frontend/package.json", in: root)
            try write("{\"name\": \"admin\"}", to: "admin/package.json", in: root)

            let projects = try ProjectDetection.detectProjects(rootDirectory: root)

            let swiftProjects = projects.filter { $0.language == "swift" }
            #expect(swiftProjects.count == 1)
            #expect(swiftProjects[0].directory.standardizedFileURL == root.standardizedFileURL)

            let rustProjects = projects.filter { $0.language == "rust" }
            #expect(rustProjects.count == 1)
            #expect(
                rustProjects[0].directory.standardizedFileURL
                    == root.appendingPathComponent("backend").standardizedFileURL)

            let tsDirectories = Set(
                projects.filter { $0.language == "typescript" }.map(\.directory.standardizedFileURL))
            #expect(
                tsDirectories == [
                    root.appendingPathComponent("frontend").standardizedFileURL,
                    root.appendingPathComponent("admin").standardizedFileURL,
                ])

            let jsDirectories = Set(
                projects.filter { $0.language == "javascript" }.map(\.directory.standardizedFileURL))
            #expect(jsDirectories == tsDirectories)
        }
    }

    @Test
    func directoryMatchingMultipleMarkersYieldsOneDetectionPerLanguage() async throws {
        try await withTemporaryWorkspace { root in
            try write("[package]\nname = \"a\"", to: "Cargo.toml", in: root)
            try write("{\"name\": \"a\"}", to: "package.json", in: root)

            let projects = try ProjectDetection.detectProjects(rootDirectory: root)

            let languages = Set(projects.map(\.language))
            #expect(languages.contains("rust"))
            #expect(languages.contains("typescript"))
            #expect(languages.contains("javascript"))
            #expect(projects.allSatisfy { $0.directory.standardizedFileURL == root.standardizedFileURL })
        }
    }

    @Test
    func directoryMatchingTwoMarkersOfSameLanguageYieldsOneDetection() async throws {
        try await withTemporaryWorkspace { root in
            try write("<project></project>", to: "pom.xml", in: root)
            try write("apply plugin: 'java'", to: "build.gradle", in: root)

            let projects = try ProjectDetection.detectProjects(rootDirectory: root)

            let javaProjects = projects.filter { $0.language == "java" }
            #expect(javaProjects.count == 1)
            #expect(javaProjects[0].directory.standardizedFileURL == root.standardizedFileURL)
        }
    }

    @Test
    func detectsCSharpProjectViaWildcardMarker() async throws {
        try await withTemporaryWorkspace { root in
            try write("<Project></Project>", to: "MyApp.csproj", in: root)

            let projects = try ProjectDetection.detectProjects(rootDirectory: root)

            #expect(projects.contains { $0.language == "csharp" })
        }
    }

    @Test
    func gitignoredSubtreeProducesNoDetections() async throws {
        try await withTemporaryWorkspace { root in
            try write("{\"name\": \"root\"}", to: "package.json", in: root)
            try write("node_modules/\n", to: ".gitignore", in: root)
            try write(
                "{\"name\": \"nested\"}",
                to: "node_modules/some-package/package.json",
                in: root)

            let projects = try ProjectDetection.detectProjects(rootDirectory: root)

            let tsProjects = projects.filter { $0.language == "typescript" }
            #expect(tsProjects.count == 1)
            #expect(tsProjects[0].directory.standardizedFileURL == root.standardizedFileURL)
        }
    }

    @Test
    func serverSpecsDedupesTwoPackageJSONHitsToOneTypeScriptLanguageServerSpec() async throws {
        try await withTemporaryWorkspace { root in
            try write("{\"name\": \"web\"}", to: "frontend/package.json", in: root)
            try write("{\"name\": \"admin\"}", to: "admin/package.json", in: root)

            let projects = try ProjectDetection.detectProjects(rootDirectory: root)
            let specs = ProjectDetection.serverSpecs(for: projects)

            let typeScriptServerSpecs = specs.filter { $0.command == "typescript-language-server" }
            #expect(typeScriptServerSpecs.count == 1)
        }
    }

    @Test
    func serverSpecsIsEmptyForNoDetectedProjects() {
        let specs = ProjectDetection.serverSpecs(for: [])
        #expect(specs.isEmpty)
    }

    @Test
    func detectedProjectRoundTripsThroughCodable() throws {
        let project = DetectedProject(language: "rust", directory: URL(fileURLWithPath: "/tmp/example"))

        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(DetectedProject.self, from: encoded)

        #expect(decoded == project)
    }
}
