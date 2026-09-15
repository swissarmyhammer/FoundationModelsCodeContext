---
assignees:
- claude-code
depends_on:
- 01M2JVXMF987MDJWG7533EJV0T
- 01M2JVYA791J25KMC3VDW4P9BJ
- 01M2JVWWAYY3VPYYH3XFAGWVZ8
position_column: todo
position_ordinal: '8680'
title: code_index tool and the public CodeContextTools factory
---
## What
Make the `code_index` tool and the one public entry point that gives a host all three tools for one `CodeContext`. Follow ALL the rules in ^6bzj7va ("Rules for every operation in every tool task": `<Verb><Noun>Operation` names in files with the same name, `@Operation(verb:noun:description:)` with all three arguments, no file or type name that is already in the module, tool resolver with verb and noun aliases).

`code_index` tool tables (all in `CodeIndexTool`):
- `verbAliases`: `check` → `get`, `refresh` → `rebuild`, `scan` → `detect`, `discover` → `detect`, `find` → `detect`, `list` → `detect`. (Real verbs: get, rebuild, detect.)
- `nounAliases`: `state` → `status`, `progress` → `status`, `index_status` → `status`, `lsp` → `lsp_status`, `servers` → `lsp_status`, `server_status` → `lsp_status`, `language_servers` → `lsp_status`, `project` → `projects`, `languages` → `projects`. (Real nouns: status, lsp_status, index, projects. `index` cannot be a noun alias for `status`, because it is a real noun of `rebuild index`.)

- [ ] `Sources/FoundationModelsCodeContext/Tools/Index/GetStatusOperation.swift` (`get`/`status`, no parameters → `indexStatus()`) and `Tools/Index/GetLspStatusOperation.swift` (`get`/`lsp_status`, no parameters → `lspStatus()`).
- [ ] `Tools/Index/RebuildIndexOperation.swift` (`rebuild`/`index`: `layer: String` (alias `target`; names `treesitter|lsp|embedding|all` mapped to `RebuildLayer` through `parseChoice(_:choices:parameter:)`, so `tree_sitter` also works); an invalid name gives a corrective string) and `Tools/Index/DetectProjectsOperation.swift` (`detect`/`projects`, no parameters → `detectProjects()`).
- [ ] `Tools/Index/CodeIndexTool.swift`: `enum CodeIndexTool` with `static let name = "code_index"`, a description, `static let verbAliases` and `static let nounAliases` (tables above), `static func operations()` and `static func make(context:)` that passes the resolver.
- [ ] `Tools/CodeContextTools.swift`: `public enum CodeContextTools` with `public static func make<Connection>(context: CodeContext<Connection>, includesSchemaInInstructions: Bool = true) throws -> [any Tool]` that returns the `code_search`, `code_navigation` and `code_index` tools built on one internal `CodeContextToolContext`; `public static let toolNames: [String]`; and `public static let operationNames: [String: [String]]` (tool name → op strings, computed from each tool's `operations()`), so code outside the module (the example, docs tests) can list the op strings without `import Operations`.
- [ ] Write every doc comment, `@Guide` description and operation description in ASD-STE100 Simplified Technical English. Every new public declaration has a doc comment.

## Acceptance Criteria
- [ ] `CodeContextTools.make(context:)` returns three tools named `code_search`, `code_navigation`, `code_index`, with 9, 10 and 4 operations.
- [ ] `CodeContextTools.operationNames` equals the op strings of the three tools.
- [ ] The only new public API is `CodeContextTools` (`make`, `toolNames`, `operationNames`).
- [ ] The alias tables of all three tools are safe: in each tool, no verb-alias key is a real verb, no noun-alias key is a real noun, every alias value is a real verb or noun, and in each operation no parameter alias normalizes to another parameter name or another alias of the same operation.
- [ ] Aliases work: `get lspstatus`, `get lsp`, `refresh index`, `scan projects`, `list project`, and `{"op": "rebuild index", "target": "tree_sitter"}` dispatch to the correct operation.
- [ ] The three tools can be given to `LanguageModelSession(tools:instructions:)` (construction only, no model call).
- [ ] `rebuild index` with `layer: "bogus"` gives a corrective string.

## Tests
- [ ] New `Tests/FoundationModelsCodeContextTests/CodeIndexToolTests.swift` (uses `import FoundationModels` and `import Operations`): each operation through `tool.call(arguments:)` against a started `CodeContext<FakeLanguageServerConnection>` in a temporary workspace with `autoInstall: LspAutoInstall(isEnabled: false)` and no project markers at `start()`. `rebuild index` with `layer: "treesitter"` returns a JSON `RebuildIndexResult`. For `detect projects`, write the `Package.swift` marker AFTER `start()` and then call the operation (`detectProjects()` only publishes projects and starts no daemon), and assert the JSON names the Swift project. Add the invalid-layer corrective test and `aliasesDispatchToTheCanonicalOperation` (the alias cases in the acceptance criteria).
- [ ] New `Tests/FoundationModelsCodeContextTests/CodeContextToolsTests.swift`: `makeReturnsTheThreeNamedTools`, `eachToolHasTheExpectedOperationCount`, `operationNamesMatchTheTools`, `aliasTablesAreSafe` (the rules in the acceptance criteria, for all three tools, read from each tool's `verbAliases`, `nounAliases` and each operation's `parameterMetadata`), `toolsCanBeRegisteredOnALanguageModelSession` (same idea as Extras `Tests/OperationsTests/OperationToolTests.swift`), and a separate file `CodeContextToolsPublicAPITests.swift` with a plain `import FoundationModelsCodeContext` (no `@testable`) that shows `CodeContextTools.make`, `toolNames` and `operationNames` are public.
- [ ] `swift build` exits 0, and `swift build --package-path IntegrationTests --build-tests` exits 0.
- [ ] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
- [ ] `swift test` exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tools #feature