---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5a1309pee12ystkn87gewx8
  text: |-
    Peer update (2026-10-19), from the SWE-bench run agent: test the hard-killed host (case b) FIRST.
    - The 19 Jedi processes came from the run that hung. There the harness killed the agent process of each instance at its time limit, and after that the remaining acp-agent processes were killed by hand. So close() most likely never ran for most pylsp sessions.
    - Nobody counted Jedi processes in the good run (152 min, 16 instances, each ended normally). There is no data for the normal-exit path yet.
    - Test that decides it: a helper host starts pylsp (or the scripted server with a grandchild) → SIGKILL the host → after N seconds, count the Jedi processes / grandchildren still alive.
    - Possible fixes if orphans stay:
      (1) A parent-death watch in pylsp's process group, e.g. a tiny watchdog in the group that waits with kqueue NOTE_EXIT on the host pid and then does killpg on its own group.
      (2) A sweep at start: on startup, find and kill groups that earlier hosts started and left behind. Record the pgid in a per-user pidfile, and check the process start time so a reused pid is never killed.
    - Start with the reproduction test, then pick the fix.
  timestamp: 2026-10-19T12:09:55.766472+00:00
- actor: claude-code
  id: 01m5a13d9jbxc0xz88dwtvn5dw
  text: |-
    Check before you count (2026-10-19 12:10): Code Context is not the only thing on this machine that starts pylsp. `sah serve` (the sah MCP server of each Claude Code session) starts pylsp too, and pylsp gets a Jedi child:
    - pid 8070 pylsp, parent 7786 `sah serve`, pgid 7660 (the pgid of the Claude session), with Jedi child 8408.
    - pid 5494 pylsp, parent 5423 `sah serve`, pgid 5386.
    These pylsp processes are NOT in their own process group. They are not ours, and they live as long as the Claude session.
    So a raw count of `jedi/.../subprocess/__main__.py` processes mixes in sah's Jedi children. In the reproduction test and in any count during a bench run, attribute each Jedi process by ancestry: parent pylsp → its parent must be the acp-agent / Code Context host, or pgid == the pgid of the pylsp that Code Context started. Orphans that were reparented to launchd (ppid 1) need the pgid to be attributed. If the cause is a sah pylsp, the bug is in swissarmyhammer, not here.
  timestamp: 2026-10-19T12:10:09.074053+00:00
- actor: claude-code
  id: 01m5a13zhebd9974crsck3dbf3
  text: 'Baseline count (2026-10-19, from the peer), with no acp-agent running: 2 Jedi processes, both from sah. 8408 under pylsp 8070 → sah serve 7786. 35923 directly under sah serve 7786, short-lived. 0 orphans (ppid 1), 0 under acp-agent. Nobody recorded the parent and process group of the 19 from the run that hung, so they cannot be attributed and may include some of sah''s. The next bench counts will record ppid and pgid. The reproduction test (SIGKILL the host, then count the leftovers) is still the deciding step.'
  timestamp: 2026-10-19T12:10:27.758726+00:00
- actor: claude-code
  id: 01m5a24ewz0tkc3d7b0251sx5b
  text: |-
    Research (2026-10-19, implement step):
    - Every path that drops a pylsp connection goes through `LSPDaemon.releaseConnection()` -> `ConnectionHandle.terminate` -> `ProcessLanguageServerConnection.close()` -> `ProcessGroupChild.terminateGroup` (SIGTERM group, 500 ms, SIGKILL group): `shutdown()`, `forceRestart()` (calls `shutdown()`), a failed `healthCheck()`, and a failed handshake (`spawnedHandle.terminate()`). `LspSupervisor.shutdown()` calls `daemon.shutdown()` for each daemon. So case (d) has no code path that skips `close()`; tests below prove it with a grandchild that ignores SIGTERM.
    - The connection sends `processId` = host pid in `initialize`, so pylsp also has its own parent watch.
    - Jedi `__main__.py` -> `Listener.listen()` reads pickled requests from stdin and calls `exit(0)` on `EOFError`. So a Jedi child exits when its pylsp exits.
    - Manual probe with a python host (pylsp in its own group, as Code Context starts it), then `kill -9` of the host:
      - idle pylsp after one hover: pylsp and its Jedi child gone within 1 s.
      - pylsp with ~3000 queued completion requests that the host never read: pylsp (now ppid 1) and Jedi stayed alive while pylsp drained the queue, both gone 25-35 s after the kill.
      So case (b) self-heals once pylsp reads EOF; the delay is bounded by the queued work.
    - Plan: integration tests (they spawn real processes, so they go in `IntegrationTests`, per test-partitioning): new scripted-server step `spawnGrandchild` (grandchild ignores SIGTERM; either sleeps, or reads its stdin pipe from the server until EOF like Jedi); tests for close(), LSPDaemon.forceRestart(), LspSupervisor shutdown/start; a hard-kill test that starts the connection from a helper host executable that uses the real `ProcessLanguageServerConnection`, SIGKILLs it, and counts the processes left in the server's process group; a real-pylsp test that counts Jedi processes by ancestry/pgid.
  timestamp: 2026-10-19T12:28:12.063153+00:00
- actor: claude-code
  id: 01m5a37p9q0hwn0jn2y1bvmcxc
  text: |-
    Implementation landed (2026-10-19). Finding: none of the stop/restart paths and not the hard-kill path leaves Jedi processes of a Code Context pylsp. Which of a-d:
    - (b) hard-killed host: TESTED FIRST, NOT a leak. `HardKilledHostTests.aHardKilledHostLeavesNoPylspOrJediProcess` (real pylsp, hover starts Jedi, asserts Jedi count > 0, SIGKILL the helper host, then counts every process in pylsp's process group): group empty within ~1 s. Scripted variant (`aHardKilledHostLeavesNoProcessOfTheScriptedServerGroup`, grandchild that ignores SIGTERM and reads a pipe from the server until EOF) also leaves 0. Mechanism: kernel closes the host pipes -> pylsp reads EOF and exits -> Jedi `Listener.listen()` reads EOF and `exit(0)`. Limit (documented on `ProcessLanguageServerConnection`): a server child that reads no pipe from the server survives a hard kill with ppid 1; Jedi is not such a child. Manual probe earlier: pylsp with a backlog of ~3000 unread requests lingers 25-35 s after the kill, then exits; bounded, no orphan. Decision: documented, no watchdog/sweep fix needed.
    - (d) restart path without close(): NOT present. Scripted grandchild (sleep, ignores SIGTERM, in the server group) is gone after `close()`, after `LSPDaemon.forceRestart()`, and after `LspSupervisor.shutdown()` in two start/shutdown rounds. Mutation check: changing `ProcessGroupChild.signalGroup` to `kill(pid, ...)` (pid only) made all 3 tests fail; reverted.
    - (c) Jedi accumulating inside one pylsp: NOT seen. `LivePylspJediTests` (3 modules, hover + definition at 2 positions each, count after every request): count stays <= 2 (and > 0), after `forceRestart` the old group is empty and the new session also stays <= 2, after `shutdown` the group is empty.
    - So the 19 of the hung run are most likely (a) many live sessions, and/or sah's own pylsp (not attributable: no ppid/pgid were recorded). Attribution must use the pgid: Code Context's pylsp leads its own group, so `ProcessTable.members(ofGroup: pylspPID)` (proc_listpids PROC_PGRP_ONLY) gives exactly its processes, also after reparenting to launchd.
    Placement: the card said "unit, scripted server" for step 1, but these tests spawn real processes, so per the test-partitioning rule (and the existing `LanguageServerProcessGroupTests`/`ScriptedLSPServerHangTests` precedent) they live in the `IntegrationTests` package. The hard-kill helper is a new executable target `LanguageServerHost` in `IntegrationTests` (uses the real `ProcessLanguageServerConnection`; the test target depends on it so SwiftPM builds it next to the test bundle).
  timestamp: 2026-10-19T12:47:26.519844+00:00
- actor: claude-code
  id: 01m5a37w64ahpbb0s5b78ee97p
  text: |-
    ### implement — changed
    - evidence: 13 files. New: IntegrationTests/Sources/LanguageServerHost/{LanguageServerHost.swift,HostConfiguration.swift}; IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/{HardKilledHostTests.swift,LanguageServerGrandchildTests.swift,LivePylspJediTests.swift,GrandchildScript.swift,HostProcess.swift,ProcessTable.swift}. Modified: IntegrationTests/Package.swift (executable target LanguageServerHost), IntegrationSupport.swift (LiveServers.isPylspOnPath), LivePylspTests.swift (uses it), Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift ("spawnGrandchild" step), Sources/.../ProcessLanguageServerConnection.swift (doc: hard-kill behavior). RED: before the step existed the 4 scripted tests failed (no grandchild pid); the real-pylsp hard-kill test passed from the start (case b self-heals). GREEN: `swift test --package-path IntegrationTests` 22 tests / 16 suites passed (0 skipped); `swift test` 1015 tests / 90 suites passed; builds with no warnings except the known mlx Cmlx "missing creator" of the IntegrationTests package. Mutation (pid-only signal) failed all 3 grandchild stop-path tests.
    - next: review
  timestamp: 2026-10-19T12:47:32.548313+00:00
- actor: claude-code
  id: 01m5a3c3gh9vzqnzmd01wqyhqp
  text: |-
    ### test — green
    - evidence: swift test — 1015 tests in 90 suites passed, 0 failed, 0 skipped; swift test --package-path IntegrationTests — 22 tests in 16 suites passed, 0 failed, 0 skipped. Only warning: pre-existing tracked mlx-swift_Cmlx "missing creator for mutated node" (not chased).
    - next: review
  timestamp: 2026-10-19T12:49:51.121171+00:00
- actor: claude-code
  id: 01m5a3d996k31shdhrpcg1x1b1
  text: |-
    ### commit — changed
    - evidence: d418a56 test: prove no Jedi or grandchild process stays after close or a killed host ^sgdcvtq
    - next: not pushed. .claude/settings.local.json is local config and was left out of the commit.
  timestamp: 2026-10-19T12:50:29.798695+00:00
position_column: doing
position_ordinal: '80'
title: 'pylsp Jedi subprocess children: prove a pylsp stop reaps them and the count does not grow in one session'
---
## What
Peer report: in a SWE-bench run of 2026-10-18 that hung, at 12:51 there were 19 processes of
`.../pipx/venvs/python-lsp-server/.../jedi/inference/compiled/subprocess/__main__.py`, and the count grew while the run went on.

## What I found (2026-10-19)
- Jedi starts its compiled subprocess with plain `subprocess.Popen` (`jedi/inference/compiled/subprocess/__init__.py` `_GeneralizedPopen`, ~line 54 and ~265 in the local pipx venv), with no `start_new_session`. So the child is in the pylsp process group.
- `ProcessLanguageServerConnection.close()` and `deinit` signal the full group (`ProcessGroupChild.terminateGroup(grace:)`, `signalGroup(SIGKILL)`), since task 01M53GM8A17VQKAC8RNPV4R1CH. So a normal stop should reap Jedi children.
- Not yet known: where the 19 came from. Candidates:
  a. 16+ sessions alive at once in the hung run (one pylsp + Jedi child each) – not a leak in Code Context.
  b. The host process was killed hard (SIGKILL / crash), so `close()` never ran. pylsp then exits on stdin EOF, but its Jedi child is reparented to launchd and may wait for ever (it reads pickled requests from pylsp's pipe; check if EOF ends it).
  c. pylsp starts one Jedi subprocess per Python environment / per workspace folder and they accumulate inside one pylsp (not our bug, but we should know).
  d. A pylsp restart path (health loop `forceRestart`, `stop lsp`/`start lsp`) that drops a connection without `close()`.

## TDD
1. Failing-or-confirming test (unit, scripted server): extend `scripted-lsp-server` with a step that starts a grandchild which ignores SIGTERM and reads stdin of its own pipe from the server. Assert after `close()`, after `forceRestart`, and after `LspSupervisor` stop/start that the grandchild pid is gone.
2. Test for case (b): start the connection from a helper host process, SIGKILL the helper, and assert the server's grandchild exits within N seconds. If it does not, fix: e.g. a watchdog in the host is impossible after SIGKILL, so options are a kqueue `NOTE_EXIT` parent watcher wrapper, or document it. Decide from the result.
3. Gated integration test in `IntegrationTests` (real pylsp, skip when absent): open a Python workspace, run several hover/definition requests across files, count Jedi `__main__.py` descendants of the pylsp pid; assert the count stays bounded (≤ 2) and is 0 after stop.
4. Fix whatever the tests show; record the finding (which of a–d) in the task.

## Acceptance
- A stop / restart of pylsp leaves 0 Jedi processes.
- In one session the Jedi count stays bounded.
- The hard-kill case is tested and either fixed or documented. #lsp #bug