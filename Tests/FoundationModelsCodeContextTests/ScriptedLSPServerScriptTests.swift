import Foundation
import ScriptedLSPServerSupport
import Testing

/// Tests for `ScriptedLSPServerScript`, the one helper that writes the script file of the
/// scripted language server for this target and for the integration package.
struct ScriptedLSPServerScriptTests {
    /// The start of the name of the directory that each test gives to the helper.
    private static let directoryPrefix = "scripted-script"

    /// The joined file holds the framing code, a line break, and the server script, in this order.
    @Test
    func theJoinedFileHoldsTheFramingCodeAndThenTheServerScript() throws {
        let directory = TemporaryItem.makeURL(prefix: Self.directoryPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = try ScriptedLSPServerScript.path(in: directory)

        let framing = try String(contentsOf: ScriptedLSPServerScript.framingSource, encoding: .utf8)
        let server = try String(contentsOf: ScriptedLSPServerScript.serverSource, encoding: .utf8)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == framing + "\n" + server)
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
    }

    /// Two calls with the same sources give the same file, thus a test run adds no new entry.
    @Test
    func twoCallsWithTheSameSourcesGiveTheSamePath() throws {
        let directory = TemporaryItem.makeURL(prefix: Self.directoryPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try ScriptedLSPServerScript.path(in: directory)
        let second = try ScriptedLSPServerScript.path(in: directory)

        #expect(first == second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [URL(fileURLWithPath: first).lastPathComponent])
    }
}
