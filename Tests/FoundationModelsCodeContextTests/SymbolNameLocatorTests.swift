import Foundation
import Testing

@testable import FoundationModelsCodeContext

/// Tests for `SymbolNameLocator`, which finds the position of the name of a
/// symbol in the source text.
///
/// A server such as `pylsp` gives a symbol range that starts at the `def`
/// keyword, and a `references` request at that position gives no result.
/// The index worker sends the request at the name instead.
struct SymbolNameLocatorTests {
    /// Splits `text` into lines, as the index worker does.
    private static func lines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    @Test
    func findsTheNameAfterTheDefKeyword() {
        let position = SymbolNameLocator.position(
            ofName: "helper",
            from: Position(line: 0, character: 0),
            throughLine: 2,
            in: Self.lines("def helper():\n    return 1\n")
        )

        #expect(position == Position(line: 0, character: 4))
    }

    @Test
    func skipsAnOccurrenceInsideALongerIdentifier() {
        let position = SymbolNameLocator.position(
            ofName: "de",
            from: Position(line: 0, character: 0),
            throughLine: 0,
            in: Self.lines("def de(x):")
        )

        #expect(position == Position(line: 0, character: 4))
    }

    @Test
    func searchesTheNextLinesOfTheSymbol() {
        let position = SymbolNameLocator.position(
            ofName: "helper",
            from: Position(line: 0, character: 0),
            throughLine: 2,
            in: Self.lines("@cache\ndef helper():\n    return 1\n")
        )

        #expect(position == Position(line: 1, character: 4))
    }

    @Test
    func startsTheSearchAtTheStartColumn() {
        let position = SymbolNameLocator.position(
            ofName: "helper",
            from: Position(line: 0, character: 9),
            throughLine: 0,
            in: Self.lines("helper = helper")
        )

        #expect(position == Position(line: 0, character: 9))
    }

    @Test
    func givesTheColumnInUTF16CodeUnits() {
        // The emoji is one character but two UTF-16 code units.
        let position = SymbolNameLocator.position(
            ofName: "helper",
            from: Position(line: 0, character: 0),
            throughLine: 0,
            in: Self.lines("x = '😀'; def helper(): pass")
        )

        #expect(position == Position(line: 0, character: 14))
    }

    @Test
    func givesNoPositionWhenTheNameIsAbsent() {
        let position = SymbolNameLocator.position(
            ofName: "missing",
            from: Position(line: 0, character: 0),
            throughLine: 1,
            in: Self.lines("def helper():\n    return 1\n")
        )

        #expect(position == nil)
    }

    @Test
    func givesNoPositionWhenTheStartLineIsAfterTheText() {
        let position = SymbolNameLocator.position(
            ofName: "helper",
            from: Position(line: 9, character: 0),
            throughLine: 12,
            in: Self.lines("def helper():\n")
        )

        #expect(position == nil)
    }
}
