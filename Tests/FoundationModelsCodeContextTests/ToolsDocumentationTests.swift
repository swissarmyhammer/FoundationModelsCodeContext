import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Proves that the documents of the package name each tool, each operation and
/// each alias that the code gives.
///
/// A new operation, or a new alias, that no document names makes a test here
/// fail. Thus `docs/tools.md` cannot move away from the code.
struct ToolsDocumentationTests {
    /// The number of path components from this file to the root of the package.
    ///
    /// This file is at `Tests/FoundationModelsCodeContextTests/ToolsDocumentationTests.swift`.
    private static let packageRootDepth = 3

    /// The root directory of the package, from the path of this file.
    private static let packageRoot: URL = {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<packageRootDepth {
            directory.deleteLastPathComponent()
        }
        return directory
    }()

    /// The alias tables of the three tools, with the name of each tool.
    private static let aliasTables: [(tool: String, verbAliases: [String: String], nounAliases: [String: String])] = [
        (tool: CodeSearchTool.name, verbAliases: CodeSearchTool.verbAliases, nounAliases: CodeSearchTool.nounAliases),
        (tool: CodeNavigationTool.name, verbAliases: CodeNavigationTool.verbAliases, nounAliases: CodeNavigationTool.nounAliases),
        (tool: CodeIndexTool.name, verbAliases: CodeIndexTool.verbAliases, nounAliases: CodeIndexTool.nounAliases),
    ]

    /// Reads one document of the package.
    ///
    /// - Parameter relativePath: The path of the document, from the root of the package.
    /// - Returns: The text of the document.
    /// - Throws: An error when the document is not there, or when it is not UTF-8.
    private static func document(at relativePath: String) throws -> String {
        try String(contentsOf: packageRoot.appending(path: relativePath), encoding: .utf8)
    }

    /// `docs/tools.md` names each op string of each tool.
    @Test
    func theToolsDocumentNamesEachOperation() throws {
        let text = try Self.document(at: "docs/tools.md")

        for (tool, operations) in CodeContextTools.operationNames {
            for operation in operations {
                #expect(text.contains(operation), "tool: \(tool), op: \(operation)")
            }
        }
    }

    /// `docs/tools.md` names each verb alias and each noun alias of each tool.
    @Test
    func theToolsDocumentNamesEachAlias() throws {
        let text = try Self.document(at: "docs/tools.md")

        for table in Self.aliasTables {
            for alias in table.verbAliases.keys.sorted() {
                #expect(text.contains(alias), "tool: \(table.tool), verb alias: \(alias)")
            }
            for alias in table.nounAliases.keys.sorted() {
                #expect(text.contains(alias), "tool: \(table.tool), noun alias: \(alias)")
            }
        }
    }

    /// `README.md` names each of the three tools.
    @Test
    func theReadmeNamesEachTool() throws {
        let text = try Self.document(at: "README.md")

        for tool in CodeContextTools.toolNames {
            #expect(text.contains(tool), "tool: \(tool)")
        }
    }
}
