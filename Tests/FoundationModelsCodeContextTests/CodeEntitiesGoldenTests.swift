import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Golden tests for ``CodeEntities``: each value is equal to the value that
/// FoundationModelsMultitool gave before it moved its code plugin into this
/// package.
///
/// `Goldens/code-entities/<language>/<case>/` holds the `before.txt` and
/// `after.txt` files of the code cases of the Multitool golden suite
/// (`GitSemanticGoldens`). The Rust `swissarmyhammer-sem` crate wrote the
/// expected diff of each case, and the Multitool code plugin matched it. A
/// throwaway program ran that Multitool code plugin (Multitool `main` at
/// `3c9856c`) on each file and wrote each entity to
/// `Goldens/code-entities-expected.json`, keyed by
/// `<language>/<case>/<side>`. Thus a match here shows that this port gives
/// the values of Multitool, and through it the values of the Rust crate.
///
/// The file path of each case is `inline<ext>`, as in the Multitool suite.
@Suite("CodeEntitiesGoldenTests")
struct CodeEntitiesGoldenTests {

    /// The folder of the source files of the cases.
    private static let casesFolder = PackagePaths.testGoldens.appending(path: "code-entities")

    /// The file of the expected entities.
    private static let expectedFile = PackagePaths.testGoldens.appending(path: "code-entities-expected.json")

    /// The file extension of the cases of each language folder.
    private static let fileExtensionByLanguage = [
        "typescript": ".ts", "tsx": ".tsx", "javascript": ".js", "jsx": ".jsx", "python": ".py", "rust": ".rs",
        "go": ".go", "swift": ".swift", "java": ".java", "c": ".c", "cpp": ".cpp", "csharp": ".cs", "ruby": ".rb",
        "php": ".php", "elixir": ".ex", "bash": ".sh",
    ]

    /// One expected entity, in the shape of the snapshot file.
    struct ExpectedEntity: Decodable, Equatable {
        let id: String
        let filePath: String
        let entityType: String
        let name: String
        let parentID: String?
        let content: String
        let contentHash: String
        let structuralHash: String?
        let startLine: Int
        let endLine: Int
        let metadata: [String: String]?
    }

    /// The expected entities of each case file, keyed by
    /// `<language>/<case>/<side>`.
    private static func expected() throws -> [String: [ExpectedEntity]] {
        try JSONDecoder().decode([String: [ExpectedEntity]].self, from: Data(contentsOf: expectedFile))
    }

    /// Each language folder of the cases, in a fixed order.
    static let languages = fileExtensionByLanguage.keys.sorted()

    /// `entity` in the shape of the snapshot file.
    private static func row(_ entity: CodeEntity) -> ExpectedEntity {
        ExpectedEntity(
            id: entity.id, filePath: entity.filePath, entityType: entity.entityType, name: entity.name,
            parentID: entity.parentID, content: entity.content, contentHash: entity.contentHash,
            structuralHash: entity.structuralHash, startLine: entity.startLine, endLine: entity.endLine,
            metadata: entity.metadata)
    }

    /// The snapshot has each case file of each language, and no other key.
    @Test("the snapshot covers each case file")
    func theSnapshotCoversEachCaseFile() throws {
        var keys: Set<String> = []
        for language in Self.languages {
            let cases = try FileManager.default.contentsOfDirectory(atPath: Self.casesFolder.appending(path: language).path)
            #expect(!cases.isEmpty, "\(language) has no case")
            for caseName in cases {
                keys.insert("\(language)/\(caseName)/before")
                keys.insert("\(language)/\(caseName)/after")
            }
        }

        #expect(Set(try Self.expected().keys) == keys)
    }

    /// Each entity of each case file of `language` is equal to the snapshot.
    @Test("the entities of each case match the snapshot", arguments: languages)
    func theEntitiesOfEachCaseMatchTheSnapshot(language: String) throws {
        let expected = try Self.expected()
        let filePath = "inline" + (Self.fileExtensionByLanguage[language] ?? "")
        let folder = Self.casesFolder.appending(path: language)

        for caseName in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() {
            for side in ["before", "after"] {
                let key = "\(language)/\(caseName)/\(side)"
                let content = try String(contentsOf: folder.appending(path: "\(caseName)/\(side).txt"), encoding: .utf8)

                let actual = CodeEntities.entities(in: content, filePath: filePath).map(Self.row)

                #expect(actual == expected[key], "\(key)")
            }
        }
    }

    /// Each language of the table has at least one case with an entity, thus
    /// a grammar that parses nothing does not pass.
    @Test("each language gives entities", arguments: languages)
    func eachLanguageGivesEntities(language: String) throws {
        let expected = try Self.expected()

        #expect(expected.filter { $0.key.hasPrefix(language + "/") }.contains { !$0.value.isEmpty })
    }
}
