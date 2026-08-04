import Testing

@testable import FoundationModelsCodeContext

/// Golden metric tests for `Complexity`: the hand-derived Sonar Cognitive
/// Complexity and max-branching-depth fixtures from the task, cross-language
/// parity for the same fixture shape, boolean-operator run counting, the
/// empty-result edge cases, and the recursion bound that keeps a pathological
/// caller-supplied snippet from overflowing the stack.
struct ComplexityTests {
  // MARK: - Fixtures

  /// Fixture A: nested loops with an `if` at the bottom.
  ///
  /// Hand-derived: `for` is a nesting increment at nesting 0 (+1), the inner
  /// `for` at nesting 1 (+2), and the `if` at nesting 2 (+3) — 6 total. The
  /// unlabeled `continue` adds nothing. The deepest stack of nesting-increment
  /// constructs is `for` → `for` → `if`, so the branching depth is 3.
  private static let fixtureASwift = """
    func sumOfPrimes(max: Int) -> Int {
        var total = 0
        for i in 2...max {
            for j in 2..<i {
                if i % j == 0 {
                    continue
                }
            }
            total += i
        }
        return total
    }
    """

  /// Fixture B: a type whose two members branch differently.
  ///
  /// Hand-derived — `classify`: the `if` at nesting 0 (+1), the `else if`
  /// clause (+1, flat), the `else` clause (+1, flat) — 3, depth 1, because an
  /// `else if` continues the chain rather than nesting inside it. `scan`: the
  /// `for` at nesting 0 (+1), the `if` at nesting 1 (+2), and one `&&` run
  /// (+1, flat) — 4, depth 2. `Calculator` aggregates its members: 3 + 4 = 7,
  /// and max(1, 2) = 2.
  private static let fixtureBSwift = """
    struct Calculator {
        func classify(_ n: Int) -> String {
            if n < 0 { return "neg" }
            else if n == 0 { return "zero" }
            else { return "pos" }
        }

        func scan(_ xs: [Int]) -> Int {
            var c = 0
            for x in xs {
                if x > 0 && x < 10 { c += 1 }
            }
            return c
        }
    }
    """

  /// Fixture A's shape in Python: the same nested `for`/`for`/`if`, so the
  /// same 6 / 3 measurement, proving the node-kind tables are not
  /// Swift-specific.
  private static let fixtureAPython = """
    def sum_of_primes(maximum):
        total = 0
        for i in range(2, maximum):
            for j in range(2, i):
                if i % j == 0:
                    continue
            total += i
        return total
    """

  /// Fixture A's shape in Rust, for the same cross-language parity reason as
  /// `fixtureAPython`.
  private static let fixtureARust = """
    fn sum_of_primes(max: u32) -> u32 {
        let mut total = 0;
        for i in 2..max {
            for j in 2..i {
                if i % j == 0 {
                    continue;
                }
            }
            total += i;
        }
        total
    }
    """

  // MARK: - Cognitive complexity and branching depth

  @Test
  func nestedLoopsAndIfAccumulateTheNestingPenalty() throws {
    let result = Complexity.measure(snippet: Self.fixtureASwift, module: SwiftLanguage.self)

    let function = try #require(result.symbols.first { $0.symbolPath == "sumOfPrimes" })
    #expect(function.kind == .function)
    #expect(function.metrics == ComplexityMetrics(cognitiveComplexity: 6, maxBranchingDepth: 3))
  }

  @Test
  func anUnlabeledContinueAddsNothing() {
    let withoutContinue = """
      func loop(_ xs: [Int]) {
          for x in xs {
              print(x)
          }
      }
      """
    let withContinue = """
      func loop(_ xs: [Int]) {
          for x in xs {
              continue
          }
      }
      """

    let baseline = Complexity.measure(snippet: withoutContinue, module: SwiftLanguage.self)
    let withJump = Complexity.measure(snippet: withContinue, module: SwiftLanguage.self)

    #expect(baseline.total == ComplexityMetrics(cognitiveComplexity: 1, maxBranchingDepth: 1))
    #expect(withJump.total == baseline.total)
  }

  @Test
  func elseAndElseIfClausesTakeAFlatIncrement() throws {
    let result = Complexity.measure(snippet: Self.fixtureBSwift, module: SwiftLanguage.self)

    let classify = try #require(result.symbols.first { $0.symbolPath == "Calculator.classify" })
    #expect(classify.metrics == ComplexityMetrics(cognitiveComplexity: 3, maxBranchingDepth: 1))
  }

  @Test
  func aGuardsMandatoryElseIsNotAnElseClause() throws {
    // tree-sitter-swift gives `guard let x else { … }` the very same named
    // `else` node it gives an `if`/`else`, as a direct child of
    // `guard_statement`. The `guard` itself is the nesting increment; its
    // `else` is mandatory syntax, not a second branch, so the pair must
    // measure 1, not 2.
    let source = """
      func unwrap(_ x: Int?) -> Int {
          guard let x else { return 0 }
          return x
      }
      """

    let result = Complexity.measure(snippet: source, module: SwiftLanguage.self)

    let function = try #require(result.symbols.first { $0.symbolPath == "unwrap" })
    #expect(function.metrics == ComplexityMetrics(cognitiveComplexity: 1, maxBranchingDepth: 1))
  }

  @Test
  func aRunOfOneRepeatedLogicalOperatorCountsOnce() throws {
    let source = """
      func all(_ a: Bool, _ b: Bool, _ c: Bool) -> Bool {
          return a && b && c
      }
      """

    let result = Complexity.measure(snippet: source, module: SwiftLanguage.self)

    let function = try #require(result.symbols.first { $0.symbolPath == "all" })
    #expect(function.metrics.cognitiveComplexity == 1)
  }

  @Test
  func aMixedRunOfTwoLogicalOperatorsCountsTwice() throws {
    let source = """
      func any(_ a: Bool, _ b: Bool, _ c: Bool) -> Bool {
          return a && b || c
      }
      """

    let result = Complexity.measure(snippet: source, module: SwiftLanguage.self)

    let function = try #require(result.symbols.first { $0.symbolPath == "any" })
    #expect(function.metrics.cognitiveComplexity == 2)
  }

  // MARK: - Aggregation

  @Test
  func aTypeAggregatesTheMembersNestedInsideIt() throws {
    let result = Complexity.measure(snippet: Self.fixtureBSwift, module: SwiftLanguage.self)

    // tree-sitter-swift has no separate node kind for a method versus a free
    // function, and `SwiftLanguage.chunkKinds` maps its one
    // `function_declaration` kind to `.function` unconditionally (see
    // `ChunkerTests.swiftMethodNestedInStructIsQualifiedByContainerName`),
    // so both members report `.function`, not `.method`.
    #expect(
      result.symbols.map(\.symbolPath) == [
        "Calculator", "Calculator.classify", "Calculator.scan",
      ])

    let calculator = try #require(result.symbols.first { $0.symbolPath == "Calculator" })
    #expect(calculator.kind == .type)
    #expect(
      calculator.metrics == ComplexityMetrics(cognitiveComplexity: 7, maxBranchingDepth: 2))

    let scan = try #require(result.symbols.first { $0.symbolPath == "Calculator.scan" })
    #expect(scan.metrics == ComplexityMetrics(cognitiveComplexity: 4, maxBranchingDepth: 2))
  }

  @Test
  func theTotalCountsEachFunctionOnceAndDoesNotDoubleCountTheEnclosingType() {
    let result = Complexity.measure(snippet: Self.fixtureBSwift, module: SwiftLanguage.self)

    #expect(result.total == ComplexityMetrics(cognitiveComplexity: 7, maxBranchingDepth: 2))
  }

  @Test
  func aNestedFunctionIsNotCountedTwiceInTheTotal() throws {
    // Both `outer` and the `inner` nested inside it are `.function` chunks,
    // and `outer`'s own walk already covers `inner`'s body — so `inner`'s
    // increment must land in `outer`'s metrics and be left out of the total.
    let source = """
      func outer(_ xs: [Int]) {
          func inner(_ x: Int) {
              if x > 0 { print(x) }
          }
          inner(1)
      }
      """

    let result = Complexity.measure(snippet: source, module: SwiftLanguage.self)

    let inner = try #require(result.symbols.first { $0.symbolPath == "outer.inner" })
    #expect(inner.metrics == ComplexityMetrics(cognitiveComplexity: 1, maxBranchingDepth: 1))
    // The nested function body raises the nesting level without adding an
    // increment of its own, so `outer` sees the same `if` at nesting 1.
    let outer = try #require(result.symbols.first { $0.symbolPath == "outer" })
    #expect(outer.metrics == ComplexityMetrics(cognitiveComplexity: 2, maxBranchingDepth: 1))
    #expect(result.total == ComplexityMetrics(cognitiveComplexity: 2, maxBranchingDepth: 1))
  }

  @Test
  func symbolLineRangeIsZeroBasedLikeSemanticChunk() throws {
    let result = Complexity.measure(snippet: Self.fixtureBSwift, module: SwiftLanguage.self)

    let classify = try #require(result.symbols.first { $0.symbolPath == "Calculator.classify" })
    #expect(classify.startLine == 1)
    #expect(classify.endLine == 5)
  }

  @Test
  func bareStatementsProduceNoSymbolsButStillMeasureATotal() {
    let source = """
      for i in 0..<10 {
          if i > 5 {
              print(i)
          }
      }
      """

    let result = Complexity.measure(snippet: source, module: SwiftLanguage.self)

    #expect(result.symbols.isEmpty)
    #expect(result.total == ComplexityMetrics(cognitiveComplexity: 3, maxBranchingDepth: 2))
  }

  // MARK: - Cross-language parity

  @Test
  func pythonMeasuresTheSameFixtureShapeIdentically() throws {
    let result = Complexity.measure(snippet: Self.fixtureAPython, module: PythonLanguage.self)

    let function = try #require(result.symbols.first { $0.symbolPath == "sum_of_primes" })
    #expect(function.metrics == ComplexityMetrics(cognitiveComplexity: 6, maxBranchingDepth: 3))
  }

  @Test
  func rustMeasuresTheSameFixtureShapeIdentically() throws {
    let result = Complexity.measure(snippet: Self.fixtureARust, module: RustLanguage.self)

    let function = try #require(result.symbols.first { $0.symbolPath == "sum_of_primes" })
    #expect(function.metrics == ComplexityMetrics(cognitiveComplexity: 6, maxBranchingDepth: 3))
  }

  // MARK: - Empty results

  @Test
  func moduleWithNoTreeSitterLanguageMeasuresNothing() {
    let result = Complexity.measure(snippet: Self.fixtureASwift, module: SQLLanguage.self)

    #expect(
      result
        == ComplexityResult(
          total: ComplexityMetrics(cognitiveComplexity: 0, maxBranchingDepth: 0),
          symbols: []))
  }

  @Test
  func unparseableSnippetMeasuresNothing() {
    let result = Complexity.measure(snippet: "@@@ ??? ###", module: SwiftLanguage.self)

    #expect(
      result
        == ComplexityResult(
          total: ComplexityMetrics(cognitiveComplexity: 0, maxBranchingDepth: 0),
          symbols: []))
  }

  @Test
  func emptySnippetMeasuresNothing() {
    let result = Complexity.measure(snippet: "", module: SwiftLanguage.self)

    #expect(
      result
        == ComplexityResult(
          total: ComplexityMetrics(cognitiveComplexity: 0, maxBranchingDepth: 0),
          symbols: []))
  }

  // MARK: - Recursion bound

  @Test
  func anASTDeeperThanTheLimitStillReportsTheSymbolsAboveIt() throws {
    // 5000 terms parse into a left-nested binary spine roughly 5000 nodes
    // deep — dozens of times past `Chunker.maxASTDepth`. An unbounded walk
    // crashes the whole test process here rather than failing an expectation,
    // so surviving this call *is* half the assertion; the other half is that a
    // snippet this deep is still measured like any other, rather than
    // degrading to no symbols at all.
    let result = Complexity.measure(
      snippet: swiftDeepExpressionSpine(termCount: 5000),
      module: SwiftLanguage.self
    )

    let function = try #require(result.symbols.first { $0.symbolPath == "deepSpine" })
    #expect(function.kind == .function)
    #expect(result.total.maxBranchingDepth <= Chunker.maxASTDepth)
  }

  @Test
  func theDepthLimitDoesNotDistortOrdinaryNesting() throws {
    let result = Complexity.measure(
      snippet: swiftNestedIfs(count: 50), module: SwiftLanguage.self)

    let function = try #require(result.symbols.first { $0.symbolPath == "deeplyNested" })
    #expect(function.metrics.maxBranchingDepth == 50)
  }
}
