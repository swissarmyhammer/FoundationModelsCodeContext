---
assignees:
- claude-code
position_column: done
position_ordinal: ff8680
title: Host-given index directory for CodeContext and CodeContextManager
---
Requested by FoundationModelsACPAgent (TestudoApp project folders live in iCloud-synced folders, so `<cwd>/.code-context/kit.db` gets synced).

Add `indexDirectory: URL? = nil` to `Store.init`, both `CodeContext` inits, and an `indexDirectory: (@Sendable (URL) -> URL)?` closure (root -> index dir) to both `CodeContextManager` inits. `nil` keeps `<root>/.code-context`. The host passes e.g. `<local home>/projects/<sha256 cwd>/code-context`.

Acceptance:
- [ ] Store opens kit.db in the given directory and creates nothing in the root
- [ ] CodeContext started with an index directory writes nothing under `<root>/.code-context`
- [ ] Manager-created contexts use the closure's directory
- [ ] Default unchanged