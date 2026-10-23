---
assignees:
- claude-code
position_column: done
position_ordinal: ff8780
title: Ref-counted acquire/release of a shared CodeContext per root in CodeContextManager
---
Requested by FoundationModelsACPAgent: ACP sessions in one process that share a cwd must share one CodeContext (one watcher, index loop, LSP fleet, DatabasePool).

- `acquire(root:) async throws -> CodeContext` — opens like `context(for:)` and adds one lease to the covering open root.
- `release(root:) async` — drops one lease of the covering open root; the last release stops and removes the context. No-op with no lease.
- Root key everywhere in the manager: `standardizedFileURL.resolvingSymlinksInPath()`, exposed as `CodeContextManager.rootKey(for:)` so hosts use the same key.
- Embedder: one per manager, by design. A second acquire cannot bring a different embedder; a host that needs another embedder makes another manager. Documented on the type.
- `close(root:)` stays a force close regardless of leases.

Acceptance:
- [ ] Two acquires of one root return the same instance; first release keeps it running, second stops it
- [ ] A symlinked path and its target share one context
- [ ] Concurrent acquires make one context and count two leases
- [ ] Acquire of a descendant leases the ancestor; release of the descendant path releases it