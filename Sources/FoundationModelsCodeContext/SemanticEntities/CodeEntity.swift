// `CodeEntity` — one named unit of a source file that a semantic diff
// compares: a function, a class, a module.
//
// A port of `model/entity.rs` in
// `../swissarmyhammer/crates/swissarmyhammer-sem/src/`: the struct
// `SemanticEntity` and the function `build_entity_id`. FoundationModelsMultitool
// maps each value to its own `SemanticEntity`, thus each value must be equal
// to the value of the Rust crate.

/// One named unit of a source file: `SemanticEntity` in `model/entity.rs`.
///
/// ``CodeEntities/entities(in:filePath:)`` makes these values.
public struct CodeEntity: Equatable, Hashable, Sendable {

    /// The stable id of the entity: `file::parent::name` for an entity with a
    /// parent, and `file::type::name` for a top-level entity.
    public let id: String

    /// The path of the file that holds the entity.
    public let filePath: String

    /// The kind of the entity, for example `function`, `class`, or `method`.
    public let entityType: String

    /// The name of the entity.
    public let name: String

    /// The id of the entity that holds this one, or `nil` for a top-level
    /// entity.
    public let parentID: String?

    /// The source text of the entity.
    public let content: String

    /// ``CodeEntities/contentHash(_:)`` of ``content``.
    public let contentHash: String

    /// The structural hash of the parse tree of the entity. Two entities with
    /// the same structural hash differ only in comments or in format. The
    /// code entities always have one; the type keeps it optional, as in Rust.
    public let structuralHash: String?

    /// The 1-based first line of the entity in the file.
    public let startLine: Int

    /// The 1-based last line of the entity in the file.
    public let endLine: Int

    /// More facts about the entity, or `nil` when there are none. The code
    /// entities have none; the type keeps it, as in Rust.
    public let metadata: [String: String]?

    /// Makes an entity from each of its values.
    ///
    /// - Parameters:
    ///   - id: The stable id of the entity.
    ///   - filePath: The path of the file that holds the entity.
    ///   - entityType: The kind of the entity.
    ///   - name: The name of the entity.
    ///   - parentID: The id of the parent entity, or `nil`.
    ///   - content: The source text of the entity.
    ///   - contentHash: The content hash of the entity.
    ///   - structuralHash: The structural hash of the entity, or `nil`.
    ///   - startLine: The 1-based first line.
    ///   - endLine: The 1-based last line.
    ///   - metadata: More facts about the entity, or `nil`.
    public init(
        id: String, filePath: String, entityType: String, name: String, parentID: String?, content: String,
        contentHash: String, structuralHash: String?, startLine: Int, endLine: Int, metadata: [String: String]?
    ) {
        self.id = id
        self.filePath = filePath
        self.entityType = entityType
        self.name = name
        self.parentID = parentID
        self.content = content
        self.contentHash = contentHash
        self.structuralHash = structuralHash
        self.startLine = startLine
        self.endLine = endLine
        self.metadata = metadata
    }
}

extension CodeEntity {

    /// The id of an entity: `build_entity_id` in `model/entity.rs`.
    ///
    /// The id is `file::parent::name` for an entity with a parent, and
    /// `file::type::name` for a top-level entity.
    ///
    /// - Parameters:
    ///   - filePath: The path of the file that holds the entity.
    ///   - entityType: The kind of the entity.
    ///   - name: The name of the entity.
    ///   - parentID: The id of the parent entity, or `nil`.
    /// - Returns: The id.
    static func makeID(filePath: String, entityType: String, name: String, parentID: String?) -> String {
        "\(filePath)::\(parentID ?? entityType)::\(name)"
    }
}
