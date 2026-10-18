/// Who uses a document that a language server has open.
///
/// A tool op (a live op such as hover or definition, or a diagnostics pull)
/// and the LSP index worker open documents through the same session. The
/// owner tells which of the two may close a document. Ports
/// `swissarmyhammer-lsp`'s `session::DocumentOwner`.
enum DocumentOwner: Sendable, Equatable {
    /// A tool op opened or used the document. A tool use is sticky: the
    /// document stays a tool document until it closes.
    case tool

    /// The LSP index worker opened the document, and no tool op used it.
    case indexer
}

/// The open-document policy of an `LspSession`: which documents the server
/// has open, who owns each one, which ones an op uses now, and which one
/// closes first when the set is at its limit.
///
/// Two rules apply:
/// - **The owner.** A sync by a tool op makes the tool ops the owner, and the
///   owner then stays `DocumentOwner.tool`. The index worker closes only a
///   document that it owns, thus it never closes a document of a tool op.
/// - **The limit.** The set holds at most `limit` documents. Before one more
///   document opens at the limit, the least recently used document that no op
///   uses now closes. Each sync marks a document as used.
///
/// The type holds no connection and does no I/O: `LspSession` sends the
/// notifications and calls this type to keep the set. Ports
/// `swissarmyhammer-lsp`'s `session::open_documents::OpenDocuments`, and adds
/// the count of the ops that use a document now.
struct OpenDocuments {
    /// The most documents that one session keeps open on the server at a
    /// time, as `MAX_OPEN_DOCUMENTS` of the Rust reference.
    ///
    /// A language server such as sourcekit-lsp does work for each open
    /// document when a file changes, thus a set with no limit costs much CPU.
    /// The value is large enough that the documents of the live tool ops stay
    /// open, and small enough that the server does little work for documents
    /// that no op uses.
    static let defaultLimit = 50

    /// One document that the server has open.
    private struct Entry {
        /// What the server knows about the document.
        var state: DocState

        /// Who uses the document.
        var owner: DocumentOwner

        /// The tick of the last use. A higher tick is a more recent use.
        var lastUse: UInt64
    }

    /// The most documents that the set holds.
    let limit: Int

    /// `uri -> ` the open document.
    private var entries: [DocumentURI: Entry] = [:]

    /// `uri -> ` the number of ops that use the document now. A document can
    /// have a use count and no entry: an op that began its use before a
    /// `removeAllEntries()` still ends its use later.
    private var useCounts: [DocumentURI: Int] = [:]

    /// The tick that the next use gets. It only goes up.
    private var clock: UInt64 = 0

    /// Creates an empty set.
    /// - Parameter limit: The most documents that the set holds.
    init(limit: Int) {
        self.limit = limit
    }

    /// Whether the set holds `limit` documents or more, thus one more
    /// document cannot open before one closes.
    var isFull: Bool {
        entries.count >= limit
    }

    /// A copy of the state of each open document, keyed by URI.
    var states: [DocumentURI: DocState] {
        entries.mapValues(\.state)
    }

    /// The state of the open document `uri`.
    /// - Parameter uri: The document to look up.
    /// - Returns: The state, or `nil` when the document is not open.
    func state(of uri: DocumentURI) -> DocState? {
        entries[uri]?.state
    }

    /// The owner of the open document `uri`.
    /// - Parameter uri: The document to look up.
    /// - Returns: The owner, or `nil` when the document is not open.
    func owner(of uri: DocumentURI) -> DocumentOwner? {
        entries[uri]?.owner
    }

    /// Whether an op uses the document `uri` now.
    /// - Parameter uri: The document to look up.
    /// - Returns: `true` when the use count of `uri` is more than zero.
    func isInUse(_ uri: DocumentURI) -> Bool {
        useCounts[uri, default: 0] > 0
    }

    /// The document that closes first when the set is full: the least
    /// recently used document that no op uses now and that is not in
    /// `excluded`.
    /// - Parameter excluded: The documents that must not close now, for
    ///   example each document that an open or a close works on now.
    /// - Returns: The URI to close, or `nil` when each open document is in use
    ///   or excluded.
    func leastRecentlyUsed(excluding excluded: Set<DocumentURI>) -> DocumentURI? {
        entries
            .filter { !excluded.contains($0.key) && !isInUse($0.key) }
            .min { $0.value.lastUse < $1.value.lastUse }?
            .key
    }

    /// Records a document that opens now, as the most recent use.
    /// - Parameters:
    ///   - uri: The document.
    ///   - state: What the server gets in the `didOpen`.
    ///   - owner: Who opens the document.
    mutating func insert(_ uri: DocumentURI, state: DocState, owner: DocumentOwner) {
        entries[uri] = Entry(state: state, owner: owner, lastUse: nextTick())
    }

    /// Marks the open document `uri` as the most recent use by `owner`.
    ///
    /// A use by a tool op makes the tool ops the owner. A use by the index
    /// worker keeps the owner. A document that is not open does not change.
    /// - Parameters:
    ///   - uri: The document.
    ///   - owner: Who uses the document.
    mutating func touch(_ uri: DocumentURI, by owner: DocumentOwner) {
        guard entries[uri] != nil else {
            return
        }
        let tick = nextTick()
        entries[uri]?.lastUse = tick
        if owner == .tool {
            entries[uri]?.owner = .tool
        }
    }

    /// Replaces the state of the open document `uri`. A document that is not
    /// open does not change.
    /// - Parameters:
    ///   - state: The new state.
    ///   - uri: The document.
    mutating func setState(_ state: DocState, of uri: DocumentURI) {
        entries[uri]?.state = state
    }

    /// Forgets the document `uri`.
    /// - Parameter uri: The document.
    mutating func remove(_ uri: DocumentURI) {
        entries.removeValue(forKey: uri)
    }

    /// Forgets each document. The use counts stay, because each op that uses
    /// a document now ends its use later.
    mutating func removeAllEntries() {
        entries.removeAll()
    }

    /// Adds one use of the document `uri`. The document need not be open.
    /// - Parameter uri: The document.
    mutating func beginUse(of uri: DocumentURI) {
        useCounts[uri, default: 0] += 1
    }

    /// Removes one use of the document `uri`. A document with no use does not
    /// change.
    /// - Parameter uri: The document.
    mutating func endUse(of uri: DocumentURI) {
        guard let count = useCounts[uri] else {
            return
        }
        useCounts[uri] = count > 1 ? count - 1 : nil
    }

    /// Gives the tick for a new use and advances the clock.
    /// - Returns: The tick.
    private mutating func nextTick() -> UInt64 {
        defer { clock += 1 }
        return clock
    }
}
