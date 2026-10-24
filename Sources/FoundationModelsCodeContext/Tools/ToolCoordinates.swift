import Foundation

/// The one place where the tools convert lines and columns between the model
/// and the engine.
///
/// The model counts lines and columns from 1, as a file reader, a compiler
/// message and a traceback do. The index, tree-sitter and the language servers
/// count from 0. Each tool input goes through the `zeroBased` functions, and
/// each tool output goes through `OneBasedEncoder`, thus no operation can
/// miss the conversion.
internal enum ToolCoordinates {
    /// The keys whose `Int` value is a line or a column, in each result that a
    /// tool gives.
    static let positionKeys: Set<String> = [
        "line", "character", "column",
        "startLine", "endLine",
        "startColumn", "endColumn",
        "startCharacter", "endCharacter",
    ]

    /// Converts a 1-based line of the model to the 0-based line of the engine.
    ///
    /// A line of 0 or less is a mistake that the operation forgives: it is
    /// line 1. `lineNote(_:)` gives the note for it.
    ///
    /// - Parameter line: The 1-based line that the model gave.
    /// - Returns: The 0-based line.
    static func zeroBased(line: Int) -> Int {
        max(line, 1) - 1
    }

    /// Converts a 1-based column of the model to the 0-based column of the
    /// engine.
    ///
    /// - Parameter character: The 1-based UTF-16 column that the model gave,
    ///   or `nil`.
    /// - Returns: The 0-based column, or `nil` when the model gave no column
    ///   or a column of 0 or less: the operation then starts at the start of
    ///   the line.
    static func zeroBased(character: Int?) -> Int? {
        guard let character, character > 0 else {
            return nil
        }
        return character - 1
    }

    /// Converts a `<file>:<line>:<column>` locator with 1-based numbers to the
    /// same locator with 0-based numbers.
    ///
    /// - Parameter locator: A locator, or a symbol name.
    /// - Returns: The locator with 0-based numbers, or `locator` unchanged when
    ///   it is a symbol name.
    static func zeroBased(locator: String) -> String {
        guard let parsed = SymbolLocator.parse(identifier: locator) else {
            return locator
        }
        return "\(parsed.filePath):\(zeroBased(line: parsed.line)):\(zeroBased(character: parsed.column) ?? 0)"
    }

    /// The note for a line that is not a 1-based line.
    ///
    /// - Parameter line: The line that the model gave.
    /// - Returns: The note, or `nil` when `line` is 1 or more.
    static func lineNote(_ line: Int) -> String? {
        line >= 1 ? nil : "Lines start at 1, thus line \(line) was read as line 1."
    }
}

/// An encoder that adds 1 to each line and each column that a tool result
/// encodes, and passes each other value to the encoder that it wraps.
///
/// A line or a column is an `Int` value whose key is in
/// `ToolCoordinates.positionKeys`, at any depth of the result.
internal struct OneBasedEncoder: Encoder {
    /// The encoder that receives the values.
    let base: any Encoder

    var codingPath: [any CodingKey] { base.codingPath }

    var userInfo: [CodingUserInfoKey: Any] { base.userInfo }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(OneBasedKeyedContainer(base: base.container(keyedBy: type)))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        OneBasedUnkeyedContainer(base: base.unkeyedContainer())
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        OneBasedSingleValueContainer(base: base.singleValueContainer())
    }
}

/// A value that encodes through a `OneBasedEncoder`, so that the conversion
/// reaches the values inside it.
private struct OneBasedValue<Value: Encodable>: Encodable {
    /// The wrapped value.
    let value: Value

    func encode(to encoder: any Encoder) throws {
        try value.encode(to: OneBasedEncoder(base: encoder))
    }

    /// Whether the base encoder must receive `value` itself: a leaf type that
    /// an encoder can encode in its own way, such as a date in a JSON
    /// encoder, and that holds no line.
    static func isLeaf(_ value: Value) -> Bool {
        value is Date || value is Data || value is URL || value is Decimal
    }
}

/// The keyed container of `OneBasedEncoder`.
private struct OneBasedKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    /// The container that receives the values.
    var base: KeyedEncodingContainer<Key>

    var codingPath: [any CodingKey] { base.codingPath }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        let isPosition = ToolCoordinates.positionKeys.contains(key.stringValue)
        try base.encode(isPosition ? value + 1 : value, forKey: key)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        if T.self == Int.self, let int = value as? Int {
            try encode(int, forKey: key)
        } else if OneBasedValue.isLeaf(value) {
            try base.encode(value, forKey: key)
        } else {
            try base.encode(OneBasedValue(value: value), forKey: key)
        }
    }

    mutating func encodeNil(forKey key: Key) throws { try base.encodeNil(forKey: key) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { try base.encode(value, forKey: key) }
    mutating func encode(_ value: String, forKey key: Key) throws { try base.encode(value, forKey: key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { try base.encode(value, forKey: key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { try base.encode(value, forKey: key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { try base.encode(value, forKey: key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { try base.encode(value, forKey: key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { try base.encode(value, forKey: key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { try base.encode(value, forKey: key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { try base.encode(value, forKey: key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { try base.encode(value, forKey: key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { try base.encode(value, forKey: key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { try base.encode(value, forKey: key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { try base.encode(value, forKey: key) }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        KeyedEncodingContainer(OneBasedKeyedContainer<NestedKey>(base: base.nestedContainer(keyedBy: keyType, forKey: key)))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        OneBasedUnkeyedContainer(base: base.nestedUnkeyedContainer(forKey: key))
    }

    mutating func superEncoder() -> any Encoder { OneBasedEncoder(base: base.superEncoder()) }

    mutating func superEncoder(forKey key: Key) -> any Encoder { OneBasedEncoder(base: base.superEncoder(forKey: key)) }
}

/// The unkeyed container of `OneBasedEncoder`. An element has no key, thus
/// the container converts no value itself; it passes the conversion to the
/// values inside each element.
private struct OneBasedUnkeyedContainer: UnkeyedEncodingContainer {
    /// The container that receives the values.
    var base: any UnkeyedEncodingContainer

    var codingPath: [any CodingKey] { base.codingPath }

    var count: Int { base.count }

    mutating func encode<T: Encodable>(_ value: T) throws {
        if OneBasedValue.isLeaf(value) {
            try base.encode(value)
        } else {
            try base.encode(OneBasedValue(value: value))
        }
    }

    mutating func encodeNil() throws { try base.encodeNil() }
    mutating func encode(_ value: Bool) throws { try base.encode(value) }
    mutating func encode(_ value: String) throws { try base.encode(value) }
    mutating func encode(_ value: Double) throws { try base.encode(value) }
    mutating func encode(_ value: Float) throws { try base.encode(value) }
    mutating func encode(_ value: Int) throws { try base.encode(value) }
    mutating func encode(_ value: Int8) throws { try base.encode(value) }
    mutating func encode(_ value: Int16) throws { try base.encode(value) }
    mutating func encode(_ value: Int32) throws { try base.encode(value) }
    mutating func encode(_ value: Int64) throws { try base.encode(value) }
    mutating func encode(_ value: UInt) throws { try base.encode(value) }
    mutating func encode(_ value: UInt8) throws { try base.encode(value) }
    mutating func encode(_ value: UInt16) throws { try base.encode(value) }
    mutating func encode(_ value: UInt32) throws { try base.encode(value) }
    mutating func encode(_ value: UInt64) throws { try base.encode(value) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        KeyedEncodingContainer(OneBasedKeyedContainer<NestedKey>(base: base.nestedContainer(keyedBy: keyType)))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        OneBasedUnkeyedContainer(base: base.nestedUnkeyedContainer())
    }

    mutating func superEncoder() -> any Encoder { OneBasedEncoder(base: base.superEncoder()) }
}

/// The single-value container of `OneBasedEncoder`. A single value has no
/// key of its own, thus the container converts no value itself.
private struct OneBasedSingleValueContainer: SingleValueEncodingContainer {
    /// The container that receives the value.
    var base: any SingleValueEncodingContainer

    var codingPath: [any CodingKey] { base.codingPath }

    mutating func encode<T: Encodable>(_ value: T) throws {
        if OneBasedValue.isLeaf(value) {
            try base.encode(value)
        } else {
            try base.encode(OneBasedValue(value: value))
        }
    }

    mutating func encodeNil() throws { try base.encodeNil() }
    mutating func encode(_ value: Bool) throws { try base.encode(value) }
    mutating func encode(_ value: String) throws { try base.encode(value) }
    mutating func encode(_ value: Double) throws { try base.encode(value) }
    mutating func encode(_ value: Float) throws { try base.encode(value) }
    mutating func encode(_ value: Int) throws { try base.encode(value) }
    mutating func encode(_ value: Int8) throws { try base.encode(value) }
    mutating func encode(_ value: Int16) throws { try base.encode(value) }
    mutating func encode(_ value: Int32) throws { try base.encode(value) }
    mutating func encode(_ value: Int64) throws { try base.encode(value) }
    mutating func encode(_ value: UInt) throws { try base.encode(value) }
    mutating func encode(_ value: UInt8) throws { try base.encode(value) }
    mutating func encode(_ value: UInt16) throws { try base.encode(value) }
    mutating func encode(_ value: UInt32) throws { try base.encode(value) }
    mutating func encode(_ value: UInt64) throws { try base.encode(value) }
}
