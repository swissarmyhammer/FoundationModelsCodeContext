---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'Limit LSP crash restarts: reset the failure count only after a healthy uptime'
---
## Problem
A server that crashes after `initialize` restarts with no limit.

- A good `start()` sets `consecutiveFailures = 0` (`Sources/FoundationModelsCodeContext/LSP/LSPDaemon.swift:329`).
- A crash after the init calls `recordFailure`, which sets the count to 1 (`:350`, `:528-537`). `restartWithBackoff` waits 2 s and starts again, and the count goes back to 0 (`:366-376`).
- Thus the limit `maxConsecutiveFailures` (5, `:129`) is never hit, and the backoff stays at 2 s. Each restart starts a full index again.
- `healthCheck()` (`:343`) only checks that the process is alive.
- When the daemon stops trying, the health loop writes a "giving up" warning at each interval with no end (`LspSupervisor.swift:355-372`).

## Change
- Record the time when the daemon goes to `.running`. Reset `consecutiveFailures` only after a minimum healthy uptime (for example 60 s). Make this value injectable for tests.
- Keep the exponential backoff and the hard limit.
- Write the "giving up" warning one time only.

## Tests
- A fake server that crashes immediately after `initialize` stops after `maxConsecutiveFailures` restarts, and the backoff becomes longer each time.
- A server that runs longer than the minimum uptime and then crashes gets its full restart budget again.
- The "giving up" warning is written one time.

## Acceptance criteria
- [ ] A crash loop after init stops at the limit.
- [ ] The tests above pass.

#lsp-fix