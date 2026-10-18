import CryptoKit
import Foundation

/// The script file that starts the scripted language server.
///
/// `swift <file>` runs one file only, but the scripted server uses the framing code of the
/// library, so that the package has one header parser. This type joins
/// `Sources/FoundationModelsCodeContext/LSP/Framing.swift` and
/// `Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift` into one file.
///
/// The name of the file holds the SHA-256 digest of its text. Thus two test runs of the same
/// sources use the same file and add no entry, and a test run of changed sources (for example in a
/// different work tree) never starts an old file.
///
/// The unit test target of the root package and the test target of the integration package both
/// use this type. Thus the join, the digest and the write have one body. Each target gives only
/// its own directory for the joined file.
public enum ScriptedLSPServerScript {
    /// The number of path components from this file to the root of the repository. This file is
    /// at `Tests/ScriptedLSPServerSupport/ScriptedLSPServerScript.swift`.
    private static let repositoryRootDepth = 3

    /// The root directory of the repository.
    private static let repositoryRoot: URL = {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<repositoryRootDepth {
            directory.deleteLastPathComponent()
        }
        return directory
    }()

    /// The framing code of the library that the script shares.
    public static let framingSource = repositoryRoot.appending(path: "Sources/FoundationModelsCodeContext/LSP/Framing.swift")

    /// The steps and the actions of the scripted server. The header comment of that file gives
    /// its script language. Do not start that file alone: start the file that `path(in:)` gives.
    public static let serverSource = repositoryRoot.appending(
        path: "Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift"
    )

    /// The start of the name of the joined file.
    private static let fileNamePrefix = "scripted-lsp-server"

    /// Writes the joined script file in `directory` if it is not there yet, and gives its path.
    /// - Parameter directory: The directory that holds the joined script file. The function makes
    ///   it if it is not there.
    /// - Returns: The absolute path of the joined script file.
    /// - Throws: The error of a read of a source file, or of the write of the joined file.
    public static func path(in directory: URL) throws -> String {
        let text = try String(contentsOf: framingSource, encoding: .utf8) + "\n" + String(contentsOf: serverSource, encoding: .utf8)
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = directory.appending(path: "\(fileNamePrefix)-\(digest).swift")
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        }
        return url.path
    }
}
