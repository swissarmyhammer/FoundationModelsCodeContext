import CryptoKit
import Foundation

/// The script file that starts the scripted language server.
///
/// `swift <file>` runs one file only, but the scripted server uses the framing code of the
/// library, so that the package has one header parser. This type joins
/// `Sources/FoundationModelsCodeContext/LSP/Framing.swift` and
/// `Support/scripted-lsp-server.swift` into one file below `TemporaryItem.root`.
///
/// The name of the file holds the SHA-256 digest of its text. Thus two test runs of the same
/// sources use the same file and add no entry, and a test run of changed sources (for example in a
/// different work tree) never starts an old file. The integration package has the same helper in
/// `ScriptedLSPServer`, because that package cannot import this test target.
enum ScriptedLSPServerScript {
    /// The framing code of the library that the script shares.
    private static let framingSource = PackagePaths.librarySources.appending(path: "LSP/Framing.swift")

    /// The steps and the actions of the scripted server.
    private static let serverSource = URL(fileURLWithPath: PackagePaths.scriptedLSPServer)

    /// The start of the name of the joined file.
    private static let fileNamePrefix = "scripted-lsp-server"

    /// Writes the joined script file if it is not there yet, and gives its path.
    /// - Returns: The absolute path of the joined script file.
    /// - Throws: The error of a read of a source file, or of the write of the joined file.
    static func path() throws -> String {
        let text = try String(contentsOf: framingSource, encoding: .utf8) + "\n" + String(contentsOf: serverSource, encoding: .utf8)
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = TemporaryItem.root.appending(path: "\(fileNamePrefix)-\(digest).swift")
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: TemporaryItem.root, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        }
        return url.path
    }
}
