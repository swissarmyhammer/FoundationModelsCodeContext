// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// SwiftPM manifest for the live `sourcekit-lsp` integration suite.
//
// Why this is a package of its own: `swift test` at the repository root must
// run the unit tests and only the unit tests, and it must do that by
// structure, not by convention. SwiftPM has no manifest-level way to hold a
// target out of the default run, and an environment-variable gate makes a
// green run that measured nothing look the same as a green run that measured
// everything. The root manifest does not name this package, so the root's
// `swift test` cannot reach it. Nothing here reads the environment for
// selection, and nothing may start to do so. The one `.enabled(if:)` trait in
// this suite reads machine capability (`sourcekit-lsp` on `$PATH`), not a
// selection variable.
//
// The two commands are:
//
//     swift test                                   # unit tests
//     swift test --package-path IntegrationTests   # this suite
//
// The compile coupling this package owes CI: the root build does not compile
// these files at all, so CI must run
// `swift build --package-path IntegrationTests --build-tests` on every run.
// A build of this package is cheap; only the run is slow. Do not drop that
// step. `.github/workflows/ci.yml` carries it in the unit job.
let package = Package(
    name: "FoundationModelsCodeContextIntegrationTests",
    // Commit to macOS 27, exactly as `../Package.swift` does; a lower floor
    // here would not resolve against it.
    platforms: [
        .macOS("27.0")
    ],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        // The live `sourcekit-lsp` smoke test suite. It uses
        // `@testable import` for the root module's internal connection
        // plumbing, so debug builds only — which is what `swift test` does.
        .testTarget(
            name: "FoundationModelsCodeContextIntegrationTests",
            dependencies: [
                .product(name: "FoundationModelsCodeContext", package: "FoundationModelsCodeContext")
            ],
            path: "Tests/FoundationModelsCodeContextIntegrationTests"
        )
    ]
)
