import SwiftTreeSitter

/// The two complexity numbers measured over one span of source: how hard it is
/// to follow, and how deeply it branches.
public struct ComplexityMetrics: Sendable, Equatable {
  /// Sonar Cognitive Complexity (Campbell): one increment per control-flow
  /// break, with each *nesting* increment additionally penalized by how deeply
  /// it is nested. Zero for straight-line code.
  public let cognitiveComplexity: Int

  /// The deepest stack of nesting-increment constructs — how far `if`s, loops,
  /// `switch`es, `catch`es, and `guard`s nest inside one another. Zero for
  /// code that never branches.
  public let maxBranchingDepth: Int

  /// Creates a metrics pair.
  ///
  /// - Parameters:
  ///   - cognitiveComplexity: The Sonar Cognitive Complexity score.
  ///   - maxBranchingDepth: The deepest nesting of branching constructs.
  public init(cognitiveComplexity: Int, maxBranchingDepth: Int) {
    self.cognitiveComplexity = cognitiveComplexity
    self.maxBranchingDepth = maxBranchingDepth
  }
}

/// One definition found in a measured snippet, with the metrics for its own
/// span.
public struct SymbolComplexity: Sendable, Equatable {
  /// The definition's qualified symbol path, e.g. `Struct.method` — the same
  /// convention as `SemanticChunk.symbolPath`, because it is produced by the
  /// same `Chunker` code.
  public let symbolPath: String

  /// The definition's meta-type, from the owning `LanguageModule`'s
  /// `chunkKinds` map.
  public let kind: SymbolMetaType

  /// The definition's zero-based start line, as `SemanticChunk.startLine`.
  public let startLine: Int

  /// The definition's zero-based end line, as `SemanticChunk.endLine`.
  public let endLine: Int

  /// The metrics measured over this definition's span.
  public let metrics: ComplexityMetrics

  /// Creates a definition's complexity entry.
  ///
  /// - Parameters:
  ///   - symbolPath: The definition's qualified symbol path.
  ///   - kind: The definition's meta-type.
  ///   - startLine: The definition's zero-based start line.
  ///   - endLine: The definition's zero-based end line.
  ///   - metrics: The metrics measured over the definition's span.
  public init(
    symbolPath: String,
    kind: SymbolMetaType,
    startLine: Int,
    endLine: Int,
    metrics: ComplexityMetrics
  ) {
    self.symbolPath = symbolPath
    self.kind = kind
    self.startLine = startLine
    self.endLine = endLine
    self.metrics = metrics
  }
}

/// A measured snippet: one entry per definition it contains, plus the snippet's
/// combined total.
public struct ComplexityResult: Sendable, Equatable {
  /// The snippet's combined metrics.
  public let total: ComplexityMetrics

  /// One entry per function, method, or type definition in the snippet,
  /// ordered by `startLine`.
  public let symbols: [SymbolComplexity]

  /// Creates a measurement result.
  ///
  /// - Parameters:
  ///   - total: The snippet's combined metrics.
  ///   - symbols: One entry per definition, ordered by `startLine`.
  public init(total: ComplexityMetrics, symbols: [SymbolComplexity]) {
    self.total = total
    self.symbols = symbols
  }
}

/// A chunk's UTF-8 byte span, standing in for the identity of the AST node it
/// was built from.
///
/// `Node` is neither `Hashable` nor `Equatable`, and two distinct nodes can
/// never occupy the same byte span, so the span is the cheapest usable key for
/// correlating a `SemanticChunk` back to the node `Chunker` derived it from.
private struct ByteRange: Hashable {
  /// The span's start offset, in UTF-8 bytes.
  let startByte: Int

  /// The span's end offset, in UTF-8 bytes.
  let endByte: Int

  /// Creates a byte span.
  init(startByte: Int, endByte: Int) {
    self.startByte = startByte
    self.endByte = endByte
  }

  /// Creates the byte span `chunk` covers.
  init(of chunk: SemanticChunk) {
    self.init(startByte: chunk.startByte, endByte: chunk.endByte)
  }
}

/// A chunk paired with the metrics measured over it, kept together so type
/// aggregation and the snippet total can still see each entry's byte span and
/// work out which entries nest inside which.
private struct MeasuredChunk {
  /// The definition this entry describes.
  let chunk: SemanticChunk

  /// The metrics measured over `chunk`'s span.
  let metrics: ComplexityMetrics
}

/// The definition nodes found by a depth-bounded walk, plus whether that walk
/// ever hit its bound.
private struct SymbolNodeIndex {
  /// Every visited node whose kind is in the module's `chunkKinds`, keyed by
  /// the byte span that identifies it.
  var nodesByRange: [ByteRange: Node] = [:]

  /// Whether the walk refused to descend somewhere, meaning the parse tree is
  /// deeper than `Complexity.maxASTDepth`.
  var reachedDepthLimit = false
}

/// What a node contributes to the metrics of the symbol it sits inside.
private enum NodeRole {
  /// A branching construct: increments by `1 + <current nesting>`, and nests
  /// everything below it one level deeper.
  case nestingIncrement

  /// A control-flow break that costs a flat `1` with no nesting penalty and no
  /// nesting of its own.
  case flatIncrement

  /// A function, method, or closure body written inside the symbol being
  /// measured: no increment of its own, but everything below it nests one
  /// level deeper.
  case nestedFunctionBody

  /// Nothing: neither an increment nor a change in nesting.
  case none
}

/// Measures Sonar Cognitive Complexity and max branching depth over a snippet of
/// source text, generic over any `LanguageModule`.
///
/// Follows the precedent `TSCallGraph.callNodeKinds` sets: rather than adding a
/// per-language requirement to `LanguageModule` — which every one of the modules
/// in `Languages.all` would have to answer — the control-flow node kinds live
/// here as private, language-agnostic tables keyed on the node-kind names the
/// grammars already share. Like that one, these tables are a **heuristic**: a
/// grammar that spells a construct differently from every other grammar simply
/// goes uncounted for that construct, and each table's doc comment names the
/// grammars its entries were verified against and the constructs it knowingly
/// misses.
///
/// Mirrors `Chunker`'s failure behavior throughout: a module with no
/// `treeSitterLanguage` and a snippet that fails to parse both measure as an
/// empty result rather than throwing.
public enum Complexity {
  // MARK: - Limits

  /// The deepest AST level this file's recursive walks descend to before they
  /// stop.
  ///
  /// `Chunker` and `TSCallGraph` walk files the indexer read off disk and take
  /// no such bound. This walk is different: it is handed arbitrary
  /// caller-supplied text, and a pathological snippet — a long chained
  /// expression such as `a + b + c + …`, which most grammars parse into a
  /// left-nested binary spine one node deep per term — would otherwise recurse
  /// until the stack overflows, which is a process crash rather than a
  /// catchable error.
  ///
  /// `512` sits an order of magnitude above ordinary source and far below
  /// where the stack runs out: a 50-deep nested-`if` fixture parses only 103
  /// levels deep, so real code is measured exactly, while a 5000-term
  /// expression spine parses 5005 levels deep and is cut off long before it
  /// can do damage. Reaching the bound is not an error — the walk reports the
  /// nodes it did visit, matching this file's degrade-quietly convention.
  ///
  /// Not `private`: `ComplexityTests` asserts both the ordinary-code and the
  /// pathological-input cases against this same number, so the test and the
  /// walk can never disagree about where the bound sits.
  static let maxASTDepth = 512

  /// The synthetic `SourceFile.relativePath` given to a caller-supplied
  /// snippet, which has no file of its own.
  ///
  /// `Chunker.chunk(file:module:)` needs a `SourceFile`, and stamps this path
  /// onto every `SemanticChunk.filePath` it produces — a field
  /// `SymbolComplexity` does not carry, so the value is never observable. The
  /// angle brackets keep it from being mistaken for a real workspace-relative
  /// path if it ever surfaces in a log.
  private static let snippetPath = "<snippet>"

  /// The result reported when there is nothing to measure.
  private static let emptyResult = ComplexityResult(
    total: ComplexityMetrics(cognitiveComplexity: 0, maxBranchingDepth: 0),
    symbols: []
  )

  // MARK: - Node kind heuristics

  /// Node kinds for the `if` half of a conditional.
  ///
  /// `if_statement` is shared by Swift, Python, JavaScript, TypeScript, TSX,
  /// Go, C, C++, Java, C#, PHP, and Bash; `if_expression` covers Rust, where a
  /// conditional is an expression. Doubles as the parent test that decides
  /// whether an `else` node is a real `else` clause — see `elseNodeKinds`.
  private static let ifNodeKinds: Set<String> = [
    "if_statement",
    "if_expression",
  ]

  /// Node kinds for a loop.
  ///
  /// `for_statement`/`while_statement` are shared by Swift, Python,
  /// JavaScript, TypeScript, TSX, Go, C, C++, Java, C#, PHP, and Bash;
  /// `for_in_statement` is JavaScript/TypeScript's `for…of`/`for…in`;
  /// `for_range_loop` is C++'s range-`for`; `foreach_statement` is C#'s and
  /// PHP's; `repeat_while_statement` is Swift's `repeat`; and
  /// `for_expression`/`while_expression`/`loop_expression` are Rust's, where
  /// loops are expressions.
  ///
  /// Java's `enhanced_for_statement` (its for-each) is here for the same
  /// reason. `do_statement` is deliberately absent — see `doWhileNodeKinds`.
  private static let loopNodeKinds: Set<String> = [
    "for_statement",
    "while_statement",
    "for_in_statement",
    "for_range_loop",
    "foreach_statement",
    "enhanced_for_statement",
    "repeat_while_statement",
    "for_expression",
    "while_expression",
    "loop_expression",
  ]

  /// Node kinds for a multi-way branch.
  ///
  /// `switch_statement` is shared by Swift, JavaScript, TypeScript, TSX, C,
  /// C++, C#, and PHP; `switch_expression` is Java's; `match_expression` is
  /// Rust's; `match_statement` is Python's; and Go spells its two forms
  /// `expression_switch_statement` and `type_switch_statement`.
  ///
  /// Only the branch itself is counted, never its individual arms, per the
  /// Sonar specification. Bash's `case` goes uncounted: it is spelled
  /// `case_statement`, which is the name C, C++, and PHP give to a *single arm
  /// inside* a `switch_statement`, so counting it would over-count those three
  /// grammars once per arm.
  private static let switchNodeKinds: Set<String> = [
    "switch_statement",
    "switch_expression",
    "match_expression",
    "match_statement",
    "expression_switch_statement",
    "type_switch_statement",
  ]

  /// Node kinds for a handler that catches a thrown error.
  ///
  /// `catch_clause` is shared by JavaScript, TypeScript, TSX, C++, Java, C#,
  /// and PHP; `catch_block` is Swift's; `except_clause` is Python's.
  private static let catchNodeKinds: Set<String> = [
    "catch_clause",
    "catch_block",
    "except_clause",
  ]

  /// Node kinds for an inline conditional expression.
  ///
  /// `ternary_expression` covers Swift, JavaScript, TypeScript, TSX, and Java;
  /// `conditional_expression` covers Python's `a if b else c` and C, C++, and
  /// C#'s `?:`.
  private static let ternaryNodeKinds: Set<String> = [
    "ternary_expression",
    "conditional_expression",
  ]

  /// Node kinds for an early-exit conditional.
  ///
  /// Only Swift has one. Its mandatory `else` is not a second branch — see
  /// `elseNodeKinds` for how that is kept from double-counting.
  private static let guardNodeKinds: Set<String> = [
    "guard_statement"
  ]

  /// Every node kind that takes a nesting increment: `+1 + <current nesting>`,
  /// nesting everything below it one level deeper.
  ///
  /// Also the set whose stacking depth `ComplexityMetrics.maxBranchingDepth`
  /// measures.
  private static let nestingIncrementNodeKinds: Set<String> =
    ifNodeKinds
    .union(loopNodeKinds)
    .union(switchNodeKinds)
    .union(catchNodeKinds)
    .union(ternaryNodeKinds)
    .union(guardNodeKinds)

  /// Node kinds that are a `do`-`while` loop in some grammars and something
  /// else entirely in others, disambiguated by the `condition` field.
  ///
  /// C, C++, Java, JavaScript, TypeScript, TSX, and C# all spell the
  /// `do`-`while` loop `do_statement` and give it a `condition` field for the
  /// trailing `while`. Swift gives the very same name to its `do { } catch { }`
  /// error-handling block, which has no `condition` field and is not a loop —
  /// so the field's presence, not the node kind alone, decides.
  private static let doWhileNodeKinds: Set<String> = [
    "do_statement"
  ]

  /// The field naming a `do`-`while` loop's trailing condition.
  private static let conditionFieldName = "condition"

  /// Node kinds for the `else` half of a conditional, each worth a flat `+1`.
  ///
  /// The grammars disagree about shape more here than anywhere else. Swift and
  /// C# emit a bare named `else` node as a direct child of the `if`; C, C++,
  /// Python, JavaScript, TypeScript, TSX, PHP, and Bash wrap it in an
  /// `else_clause`; Rust wraps both `else` and `else if` in an `else_clause`;
  /// Java and Go emit an anonymous `else` token as a direct child of the `if`;
  /// and Python, PHP, and Bash give `else if` its own `elif_clause` /
  /// `else_if_clause` node.
  ///
  /// A node here only takes its increment when its **parent** is in
  /// `ifNodeKinds`, which resolves all of that in one rule and rules out three
  /// look-alikes that must not count: the `else` token nested inside an
  /// `else_clause` (already counted as the clause), Swift's mandatory
  /// `guard … else`, and Python's `for`/`while`/`try` `else_clause`, none of
  /// which is a second branch of a conditional.
  private static let elseNodeKinds: Set<String> = [
    "else",
    "else_clause",
    "elif_clause",
    "else_if_clause",
  ]

  /// Node kinds for an unconditional jump to a label, each worth a flat `+1`.
  ///
  /// `goto_statement` is shared by C, C++, C#, Go, and PHP — every grammar
  /// here that has a `goto` at all.
  private static let gotoNodeKinds: Set<String> = [
    "goto_statement"
  ]

  /// Node kinds for a `break` or `continue`, which is worth a flat `+1` only
  /// when it carries a label — see `jumpLabelNodeKinds`.
  ///
  /// `break_statement`/`continue_statement` are shared by Python, JavaScript,
  /// TypeScript, TSX, Go, C, C++, Java, C#, and PHP; `break_expression`/
  /// `continue_expression` are Rust's.
  ///
  /// Swift is absent on purpose: tree-sitter-swift parses `return`, `break`,
  /// and `continue` into one `control_transfer_statement` kind, so a labeled
  /// `continue` cannot be told apart from a `return` of a value, and counting
  /// the kind would count every `return` in the language.
  private static let jumpNodeKinds: Set<String> = [
    "break_statement",
    "continue_statement",
    "break_expression",
    "continue_expression",
  ]

  /// The field naming a jump's label, where the grammar declares one.
  ///
  /// JavaScript, TypeScript, and TSX put their `break`/`continue` label
  /// behind this field; C and C++ put a `goto`'s target behind it.
  private static let jumpLabelFieldName = "label"

  /// Node kinds dedicated to a jump's label, for the grammars that declare no
  /// field for it.
  ///
  /// `label` is Rust's, `label_name` is Go's, and `statement_identifier` is the
  /// JavaScript family's.
  ///
  /// Java is knowingly missed: it models a labeled `continue`'s target as a
  /// bare `identifier`, which is exactly how Rust models `break <value>`, so
  /// accepting `identifier` here would count every Rust break-with-value as a
  /// labeled jump. Missing an increment is the safer of the two errors.
  private static let jumpLabelNodeKinds: Set<String> = [
    "label",
    "label_name",
    "statement_identifier",
  ]

  /// Node kinds for a binary expression that *may* be a logical operator.
  ///
  /// `binary_expression` is shared by Rust, Go, C, C++, Java, C#, PHP,
  /// JavaScript, TypeScript, and TSX, and covers arithmetic and comparison
  /// too, so the operator token decides — see `logicalOperatorNodeKinds`.
  /// `boolean_operator` is Python's, which covers `and` and `or` alone, and
  /// Swift splits the two into `conjunction_expression` and
  /// `disjunction_expression`.
  private static let binaryOperatorNodeKinds: Set<String> = [
    "binary_expression",
    "boolean_operator",
    "conjunction_expression",
    "disjunction_expression",
  ]

  /// The fields tried, in order, to find a binary expression's operator token.
  ///
  /// Every grammar here names it `operator` except tree-sitter-swift, which
  /// names it `op`.
  private static let binaryOperatorFieldNames = ["operator", "op"]

  /// The operator tokens that make a binary expression a logical one.
  ///
  /// An operator token is anonymous, and an anonymous node's `nodeType` is its
  /// literal spelling — so these are node kinds *and* the source text they
  /// stand for at the same time, and matching on the kind avoids extracting
  /// text from the source for every binary expression in the tree.
  private static let logicalOperatorNodeKinds: Set<String> = ["&&", "||", "and", "or"]

  /// Node kinds for a function body written inline as a value.
  ///
  /// A body like this raises the nesting level of everything inside it without
  /// taking an increment of its own. `lambda_literal` is Swift's, `lambda`
  /// Python's, `closure_expression` Rust's, `func_literal` Go's,
  /// `anonymous_function` PHP's, `lambda_expression` C++'s, Java's, and C#'s,
  /// and `arrow_function`/`function_expression` the JavaScript family's.
  ///
  /// A module's own named functions and methods are added on top of this table
  /// from its `chunkKinds` — see `functionNodeKinds(of:)`.
  private static let closureNodeKinds: Set<String> = [
    "lambda_literal",
    "lambda",
    "closure_expression",
    "func_literal",
    "anonymous_function",
    "lambda_expression",
    "arrow_function",
    "function_expression",
  ]

  // MARK: - Public entry point

  /// Measures `snippet`, parsed with `module`'s tree-sitter grammar.
  ///
  /// Reports one `SymbolComplexity` per definition `Chunker` finds whose kind
  /// is `.function`, `.method`, or `.type`. A function or method is measured by
  /// walking its own subtree with the nesting level reset at its own node, so a
  /// function nested inside another is measured twice — once on its own, and
  /// once as part of its enclosing function, where it also raises the nesting
  /// level. A type's entry is the sum of the cognitive complexity, and the max
  /// of the branching depth, of the functions and methods nested inside it.
  ///
  /// `total` counts each function and method exactly once, skipping any that is
  /// nested inside another, so an enclosing function and a closure inside it
  /// are not both added; its branching depth is the max over every entry. A
  /// snippet with no entries at all — bare statements, or a parse tree too deep
  /// to identify symbols in — falls back to `total` measured over the whole
  /// parse tree.
  ///
  /// Returns an empty result — rather than throwing — if `module` has no
  /// `treeSitterLanguage` or parsing fails, matching
  /// `Chunker.chunk(file:module:)`.
  ///
  /// - Parameters:
  ///   - snippet: The source text to measure.
  ///   - module: The language module supplying the grammar and chunk-kind
  ///     tables.
  /// - Returns: One entry per definition, ordered by start line, plus the
  ///   snippet's total.
  public static func measure(snippet: String, module: any LanguageModule.Type) -> ComplexityResult {
    guard let (_, root) = Chunker.parseFile(contents: snippet, module: module) else {
      return emptyResult
    }

    let functionNodeKinds = functionNodeKinds(of: module)
    var index = SymbolNodeIndex()
    indexSymbolNodes(node: root, module: module, source: snippet, astDepth: 0, into: &index)

    // `Chunker.chunk(file:module:)` walks the tree with an unbounded
    // recursion of its own, so it is only safe on a tree the bounded walk
    // above got all the way through. A deeper tree degrades to no symbols at
    // all rather than crashing the process — see `maxASTDepth`, and the task
    // filed to bound `Chunker`'s own walk.
    let chunks =
      index.reachedDepthLimit
      ? []
      : Chunker.chunk(
        file: SourceFile(relativePath: snippetPath, contents: snippet), module: module)

    let functions = measuredFunctions(
      chunks: chunks, index: index, functionNodeKinds: functionNodeKinds)
    let entries = entries(chunks: chunks, functions: functions)

    guard !entries.isEmpty else {
      return ComplexityResult(
        total: metrics(under: root, functionNodeKinds: functionNodeKinds),
        symbols: []
      )
    }

    return ComplexityResult(
      total: total(functions: functions, entries: entries),
      symbols: orderedByStartLine(entries)
    )
  }

  // MARK: - Symbol identification

  /// The node kinds whose bodies raise the nesting level: `module`'s own
  /// named functions and methods, plus every inline closure kind.
  ///
  /// - Parameter module: The language module whose `chunkKinds` to read.
  /// - Returns: `closureNodeKinds` plus every `chunkKinds` entry mapping to
  ///   `.function` or `.method`.
  private static func functionNodeKinds(of module: any LanguageModule.Type) -> Set<String> {
    var kinds = closureNodeKinds
    for (nodeKind, metaType) in module.chunkKinds
    where metaType == .function || metaType == .method {
      kinds.insert(nodeKind)
    }
    return kinds
  }

  /// Recurses `node` and its descendants, recording every node whose kind is in
  /// `module.chunkKinds` against the byte span that identifies it.
  ///
  /// Mirrors `Chunker.collectChunks(node:file:module:into:)` — same pre-order,
  /// same recursion into every child named and anonymous alike — but stops
  /// descending at `maxASTDepth` and reports having done so, which is the
  /// signal `measure(snippet:module:)` uses to decide whether `Chunker`'s own
  /// unbounded walk can safely be run over the same tree.
  ///
  /// - Parameters:
  ///   - node: The node to walk.
  ///   - module: The language module supplying the chunk-kind table.
  ///   - source: The text `node` was parsed from, for resolving byte offsets.
  ///   - astDepth: How far below the walk's root `node` sits.
  ///   - index: The index to record definition nodes into.
  private static func indexSymbolNodes(
    node: Node,
    module: any LanguageModule.Type,
    source: String,
    astDepth: Int,
    into index: inout SymbolNodeIndex
  ) {
    guard astDepth < maxASTDepth else {
      index.reachedDepthLimit = true
      return
    }

    if module.chunkKinds[node.nodeType ?? ""] != nil,
      let (_, startByte, endByte) = Chunker.extractTextAndRange(of: node, in: source)
    {
      index.nodesByRange[ByteRange(startByte: startByte, endByte: endByte)] = node
    }

    for childIndex in 0..<node.childCount {
      guard let child = node.child(at: childIndex) else {
        continue
      }
      indexSymbolNodes(
        node: child, module: module, source: source, astDepth: astDepth + 1, into: &index)
    }
  }

  /// Measures every `.function` and `.method` chunk against the node it came
  /// from, in `chunks`' own pre-order.
  ///
  /// - Parameters:
  ///   - chunks: Every chunk `Chunker` found in the snippet.
  ///   - index: The definition nodes to measure against.
  ///   - functionNodeKinds: The node kinds whose bodies raise the nesting level.
  /// - Returns: One measured entry per function or method chunk whose node the
  ///   index holds.
  private static func measuredFunctions(
    chunks: [SemanticChunk],
    index: SymbolNodeIndex,
    functionNodeKinds: Set<String>
  ) -> [MeasuredChunk] {
    chunks.compactMap { chunk in
      guard chunk.kind == .function || chunk.kind == .method,
        let node = index.nodesByRange[ByteRange(of: chunk)]
      else {
        return nil
      }
      return MeasuredChunk(
        chunk: chunk, metrics: metrics(under: node, functionNodeKinds: functionNodeKinds))
    }
  }

  /// Builds the reportable entries — functions, methods, and the types that
  /// aggregate them — in `chunks`' own pre-order.
  ///
  /// - Parameters:
  ///   - chunks: Every chunk `Chunker` found in the snippet.
  ///   - functions: The already-measured function and method entries.
  /// - Returns: One entry per chunk whose kind is `.function`, `.method`, or
  ///   `.type`; `.other` chunks (an `impl` block, a module, a constant) carry
  ///   no metrics of their own and are dropped.
  private static func entries(chunks: [SemanticChunk], functions: [MeasuredChunk])
    -> [MeasuredChunk]
  {
    var metricsByRange: [ByteRange: ComplexityMetrics] = [:]
    for function in functions {
      metricsByRange[ByteRange(of: function.chunk)] = function.metrics
    }

    return chunks.compactMap { chunk in
      switch chunk.kind {
      case .function, .method:
        guard let metrics = metricsByRange[ByteRange(of: chunk)] else {
          return nil
        }
        return MeasuredChunk(chunk: chunk, metrics: metrics)
      case .type:
        return MeasuredChunk(chunk: chunk, metrics: aggregate(of: chunk, over: functions))
      case .other:
        return nil
      }
    }
  }

  // MARK: - Metric walk

  /// Measures the subtree under `node`, with the nesting level reset at `node`
  /// itself.
  ///
  /// Walks `node`'s children rather than `node`, so that measuring a function
  /// does not have that function's own body count as a nested one: only
  /// function bodies found *below* the symbol being measured raise the nesting
  /// level.
  ///
  /// - Parameters:
  ///   - node: The node whose subtree to measure.
  ///   - functionNodeKinds: The node kinds whose bodies raise the nesting level.
  /// - Returns: The metrics accumulated over the subtree.
  private static func metrics(under node: Node, functionNodeKinds: Set<String>)
    -> ComplexityMetrics
  {
    var cognitiveComplexity = 0
    var maxBranchingDepth = 0

    for childIndex in 0..<node.childCount {
      guard let child = node.child(at: childIndex) else {
        continue
      }
      accumulate(
        node: child,
        functionNodeKinds: functionNodeKinds,
        nesting: 0,
        branchDepth: 0,
        astDepth: 1,
        cognitiveComplexity: &cognitiveComplexity,
        maxBranchingDepth: &maxBranchingDepth
      )
    }

    return ComplexityMetrics(
      cognitiveComplexity: cognitiveComplexity, maxBranchingDepth: maxBranchingDepth)
  }

  /// Adds `node`'s own contribution to the running metrics, then recurses into
  /// its children at whatever nesting level `node` leaves behind.
  ///
  /// Stops descending at `maxASTDepth` without throwing: what was reached is
  /// what gets reported.
  ///
  /// - Parameters:
  ///   - node: The node to score.
  ///   - functionNodeKinds: The node kinds whose bodies raise the nesting level.
  ///   - nesting: How many nesting increments and function bodies enclose
  ///     `node`, which is the penalty a nesting increment here pays.
  ///   - branchDepth: How many nesting increments alone enclose `node`.
  ///   - astDepth: How far below the walk's root `node` sits.
  ///   - cognitiveComplexity: The running Cognitive Complexity score.
  ///   - maxBranchingDepth: The deepest `branchDepth` reached so far.
  private static func accumulate(
    node: Node,
    functionNodeKinds: Set<String>,
    nesting: Int,
    branchDepth: Int,
    astDepth: Int,
    cognitiveComplexity: inout Int,
    maxBranchingDepth: inout Int
  ) {
    guard astDepth < maxASTDepth else {
      return
    }

    var childNesting = nesting
    var childBranchDepth = branchDepth

    switch role(of: node, functionNodeKinds: functionNodeKinds) {
    case .nestingIncrement:
      cognitiveComplexity += 1 + nesting
      childNesting = nesting + 1
      childBranchDepth = branchDepth + 1
      maxBranchingDepth = max(maxBranchingDepth, childBranchDepth)
    case .flatIncrement:
      cognitiveComplexity += 1
    case .nestedFunctionBody:
      childNesting = nesting + 1
    case .none:
      break
    }

    for childIndex in 0..<node.childCount {
      guard let child = node.child(at: childIndex) else {
        continue
      }
      accumulate(
        node: child,
        functionNodeKinds: functionNodeKinds,
        nesting: childNesting,
        branchDepth: childBranchDepth,
        astDepth: astDepth + 1,
        cognitiveComplexity: &cognitiveComplexity,
        maxBranchingDepth: &maxBranchingDepth
      )
    }
  }

  /// Classifies what `node` contributes to the symbol it sits inside.
  ///
  /// - Parameters:
  ///   - node: The node to classify.
  ///   - functionNodeKinds: The node kinds whose bodies raise the nesting level.
  /// - Returns: `node`'s role.
  private static func role(of node: Node, functionNodeKinds: Set<String>) -> NodeRole {
    let kind = node.nodeType ?? ""

    if isNestingIncrement(node: node, kind: kind) {
      // An `else if`'s `if` half is not a branch of its own: the `else`
      // half already took the chain's flat increment, and the Sonar
      // specification keeps the whole chain at one nesting level rather
      // than nesting each `else if` inside the last.
      return continuesAnElseIfChain(node: node, kind: kind) ? .none : .nestingIncrement
    }
    if takesFlatIncrement(node: node, kind: kind) {
      return .flatIncrement
    }
    if functionNodeKinds.contains(kind) {
      return .nestedFunctionBody
    }
    return .none
  }

  /// Whether `node` is a branching construct that nests what it contains.
  private static func isNestingIncrement(node: Node, kind: String) -> Bool {
    if nestingIncrementNodeKinds.contains(kind) {
      return true
    }
    return doWhileNodeKinds.contains(kind) && node.child(byFieldName: conditionFieldName) != nil
  }

  /// Whether `node` is the `if` half of an `else if`, rather than a
  /// conditional of its own.
  ///
  /// Two shapes say so, and between them they cover every grammar here: the
  /// `if` hangs off an `else` node (Rust, C, C++, Python, JavaScript,
  /// TypeScript, TSX), or it directly follows one among its siblings (Swift,
  /// Java, Go, C#).
  private static func continuesAnElseIfChain(node: Node, kind: String) -> Bool {
    guard ifNodeKinds.contains(kind) else {
      return false
    }
    if let parentKind = node.parent?.nodeType, elseNodeKinds.contains(parentKind) {
      return true
    }
    if let previousKind = node.previousSibling?.nodeType, elseNodeKinds.contains(previousKind) {
      return true
    }
    return false
  }

  /// Whether `node` costs a flat `1` with no nesting penalty.
  private static func takesFlatIncrement(node: Node, kind: String) -> Bool {
    if isElseClause(node: node, kind: kind) {
      return true
    }
    if gotoNodeKinds.contains(kind) {
      return true
    }
    if isLabeledJump(node: node, kind: kind) {
      return true
    }
    return startsALogicalOperatorRun(node: node, kind: kind)
  }

  /// Whether `node` is the `else` half of a conditional.
  ///
  /// Requiring the parent to be an `if` is what separates a real `else` from
  /// the three look-alikes `elseNodeKinds` documents.
  private static func isElseClause(node: Node, kind: String) -> Bool {
    guard elseNodeKinds.contains(kind), let parentKind = node.parent?.nodeType else {
      return false
    }
    return ifNodeKinds.contains(parentKind)
  }

  /// Whether `node` is a `break` or `continue` that names a label, which makes
  /// it a jump a reader has to follow rather than a local exit.
  private static func isLabeledJump(node: Node, kind: String) -> Bool {
    guard jumpNodeKinds.contains(kind) else {
      return false
    }
    if node.child(byFieldName: jumpLabelFieldName) != nil {
      return true
    }
    for childIndex in 0..<node.childCount {
      guard let childKind = node.child(at: childIndex)?.nodeType else {
        continue
      }
      if jumpLabelNodeKinds.contains(childKind) {
        return true
      }
    }
    return false
  }

  /// Whether `node` begins a run of one logical operator, which the Sonar
  /// specification scores once per run rather than once per operator.
  ///
  /// A chain of one repeated operator parses into nested binary nodes that all
  /// carry that same operator, so a node continues the run it sits in exactly
  /// when its parent is a logical binary node with the same operator — and
  /// begins a new one otherwise. `a && b && c` is therefore one run, while
  /// `a && b || c` is two.
  private static func startsALogicalOperatorRun(node: Node, kind: String) -> Bool {
    guard let logicalOperator = logicalOperator(of: node, kind: kind) else {
      return false
    }
    guard let parent = node.parent, let parentKind = parent.nodeType else {
      return true
    }
    return self.logicalOperator(of: parent, kind: parentKind) != logicalOperator
  }

  /// The logical operator `node` applies, or `nil` if it is not a logical
  /// binary expression at all.
  ///
  /// - Parameters:
  ///   - node: The node to read an operator off.
  ///   - kind: `node`'s kind, already resolved by the caller.
  /// - Returns: The operator's spelling — which is also its node kind, since
  ///   the operator token is anonymous — or `nil`.
  private static func logicalOperator(of node: Node, kind: String) -> String? {
    guard binaryOperatorNodeKinds.contains(kind) else {
      return nil
    }
    for fieldName in binaryOperatorFieldNames {
      guard let operatorKind = node.child(byFieldName: fieldName)?.nodeType else {
        continue
      }
      return logicalOperatorNodeKinds.contains(operatorKind) ? operatorKind : nil
    }
    return nil
  }

  // MARK: - Aggregation

  /// Sums the cognitive complexity, and takes the max branching depth, of the
  /// functions and methods nested inside `type`.
  private static func aggregate(of type: SemanticChunk, over functions: [MeasuredChunk])
    -> ComplexityMetrics
  {
    let members = functions.filter { contains(type, $0.chunk) }
    return ComplexityMetrics(
      cognitiveComplexity: members.reduce(0) { $0 + $1.metrics.cognitiveComplexity },
      maxBranchingDepth: members.map(\.metrics.maxBranchingDepth).max() ?? 0
    )
  }

  /// The snippet's combined metrics.
  ///
  /// Sums only the functions and methods that no *other* function or method
  /// encloses, because an enclosing function's own walk already covered
  /// everything nested inside it — without that filter, a JavaScript
  /// `arrow_function` inside a `function_declaration`, both of which
  /// `SharedChunkKinds.javaScriptFamily` maps to `.function`, would be counted
  /// twice. Branching depth is the max over every entry, types included, since
  /// depth does not accumulate the way a count does.
  private static func total(functions: [MeasuredChunk], entries: [MeasuredChunk])
    -> ComplexityMetrics
  {
    let outermost = functions.filter { candidate in
      !functions.contains { contains($0.chunk, candidate.chunk) }
    }
    return ComplexityMetrics(
      cognitiveComplexity: outermost.reduce(0) { $0 + $1.metrics.cognitiveComplexity },
      maxBranchingDepth: entries.map(\.metrics.maxBranchingDepth).max() ?? 0
    )
  }

  /// Whether `outer` strictly encloses `inner`.
  ///
  /// Compares byte spans rather than the line ranges `SymbolComplexity`
  /// reports: two definitions can share a line — `struct S { func f() {} }` is
  /// one line holding both — and line ranges alone would make each of them
  /// look like it contained the other.
  private static func contains(_ outer: SemanticChunk, _ inner: SemanticChunk) -> Bool {
    ByteRange(of: outer) != ByteRange(of: inner)
      && outer.startByte <= inner.startByte
      && inner.endByte <= outer.endByte
  }

  /// Converts measured chunks into reportable entries ordered by start line.
  ///
  /// The sort is made stable by breaking ties on the entry's existing
  /// position, so definitions that begin on the same line keep the AST
  /// pre-order `Chunker` produced them in — outermost first.
  private static func orderedByStartLine(_ entries: [MeasuredChunk]) -> [SymbolComplexity] {
    entries.enumerated()
      .sorted {
        ($0.element.chunk.startLine, $0.offset) < ($1.element.chunk.startLine, $1.offset)
      }
      .map { _, entry in
        SymbolComplexity(
          symbolPath: entry.chunk.symbolPath,
          kind: entry.chunk.kind,
          startLine: entry.chunk.startLine,
          endLine: entry.chunk.endLine,
          metrics: entry.metrics
        )
      }
  }
}
