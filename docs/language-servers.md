# Language servers

`start()` finds the languages below the root directory, maps each language
to its language server, and starts one daemon for each server binary. When a
server binary is not on `$PATH`, `CodeContext` **installs it automatically
by default**. It runs the native global installer of that ecosystem
(`rustup`, `go`, `pipx`, `npm`, or `brew`). Each command runs only if that
installer tool is present. Then `CodeContext` does the check again and
starts the server.

A server with an installation in progress shows as `.installing` in
`CodeContextState.servers`. When the installation is complete, the server
shows as `.running` (installed) or `.notFound` (not found). Each command
runs one time as a maximum in a session, so a failed installation cannot
loop. A failed command also waits 24 hours before any other session runs it
again; see below.

| Language(s) | Server | Auto-install command | Installer tool |
|---|---|---|---|
| Rust | `rust-analyzer` | `rustup component add rust-analyzer` | `rustup` |
| Go | `gopls` | `go install golang.org/x/tools/gopls@latest` | `go` |
| Python | `pylsp` | `pipx install python-lsp-server` | `pipx` |
| TypeScript / JavaScript / TSX | `typescript-language-server` | `npm install -g typescript-language-server typescript@6` | `npm` |
| PHP | `intelephense` | `npm install -g intelephense` | `npm` |
| Java | `jdtls` | `brew install jdtls` | `brew` |
| Swift | `sourcekit-lsp` | hint only — install Xcode or a Swift toolchain | — |
| C / C++ | `clangd` | hint only — install with your package manager | — |
| C# | `omnisharp` | hint only — install OmniSharp | — |

The last three are **hint-only**: no automatic installer is available for
them, because they need a full toolchain or their installations are not
reliable. A missing binary stays `.notFound` and shows its install hint.
This is the same behavior these servers had before auto-install existed.

The TypeScript install pins TypeScript to major 6. TypeScript 7, the npm
`latest` tag, is the native rewrite, and its package has no
`lib/tsserver.js`. `typescript-language-server` needs that file, so with
TypeScript 7 it fails `initialize` with "Could not find a valid TypeScript
installation". A machine that already has TypeScript 7 as its global
`typescript` keeps it, because `typescript-language-server` is on `$PATH` and
no install runs. Run `npm install -g typescript@6` one time on that machine.

## How to control auto-install

Give an `LspAutoInstall` when you construct a `CodeContext` or a
`CodeContextManager`. With it you can stop auto-install, or change the
maximum time an installation can run before it is a failure:

```swift
// Never auto-install; give install-hint-only guidance for each server.
let context = try await CodeContext(
    rootDirectory: repoURL,
    embedder: embedder,
    autoInstall: LspAutoInstall(isEnabled: false)
)

// Keep auto-install on, but limit each install command to 120 seconds
// (the default is 300).
let manager = await CodeContextManager(
    embedder: embedder,
    autoInstall: LspAutoInstall(timeout: .seconds(120))
)
```

The default `LspAutoInstall()` is on and has a 300-second time limit for
each installation. Callers that do not give the argument get auto-install
with no code change.

An installation runs in the background: `start()` does not wait for it, and
`stop()` stops it. A host that runs for a short time, for example an agent
that works on one task, can give a lower `timeout`, or turn auto-install
off and install its language servers before it starts.

When the time limit elapses, or when the session stops, the installer is
stopped with all the processes that it started (for example the `node` and
`git` processes of `npm`): they get `SIGTERM`, and after 2 seconds `SIGKILL`.
No process of the installer stays after the stop, and none keeps a lock
for the next session. Thus a stop never takes much longer than the time
limit.

## A failed installation is not tried again for 24 hours

A failed installation (a nonzero exit, a timeout, or an installer that
does not start) is written to a record of the user, not of the workspace:
`~/Library/Caches/FoundationModelsCodeContext/install-failures.json`. The
record holds one entry for each installer command (the server command,
the installer tool and its arguments) with the failure time, the exit
code and the error code of the output (for example the `npm` code
`UNABLE_TO_GET_ISSUER_CERT_LOCALLY`). Each session of each workspace on
the machine reads it. While an entry is younger than `failureBackoff`
(default 24 hours), no session runs that installer command again: the
server stays `.notFound`, and the `lsp` logger writes at info "the
installer of the language server failed before; it is not tried again
until the retry time", with the reason and the retry time
(`lsp.install.retry_time`). Thus an installer that fails because of the
machine (a certificate, a proxy, a missing toolchain) runs one time a day,
not one time for each new clone.

A successful installation removes its entry. A changed installer command
(other arguments, another version) has its own entry, so it runs at once.
A record that cannot be read or written never stops an installation; the
logger writes a warning and the installation goes on.

To try every failed installation again now, delete the record file:

```sh
rm ~/Library/Caches/FoundationModelsCodeContext/install-failures.json
```

To change the window, or the place of the record, give the values to
`LspAutoInstall`. A `nil` directory keeps no record, thus each session
tries a failed installation again:

```swift
let manager = await CodeContextManager(
    embedder: embedder,
    autoInstall: LspAutoInstall(
        failureBackoff: .seconds(60 * 60),
        failureRecordDirectory: URL(fileURLWithPath: "/shared/cache/code-context")
    )
)
```

## Server capabilities

Not all servers have all methods. `CodeContext` reads the capabilities that
each server gives in its `initialize` result, and it sends call hierarchy,
workspace symbol and implementation requests only to a server that
advertises them. For example, `pylsp` has none of these three.

When a server has no call hierarchy, the callers come from
`textDocument/references` instead. The index keeps a call edge from the
function or method around each reference to the referenced symbol, and
`get callgraph`, `get inbound_calls` and `get blastradius` read these edges.
A reference is not always a call (a function passed as a value is a
reference too), so these callers are a close approximation.

When a request fails, the log shows the server, the request, the error case
(`error.case`, for example `serverError`) and the JSON-RPC code of the server
error (`lsp.error_code`, for example `-32603`). It never shows the message of
the server, because a message can hold content. The log has one line for each
(server, request) pair, not one line for each symbol. When the handshake
fails, the record "the language server daemon failed" shows the same error
case and code, with `lsp.request` = `initialize`.

## What an empty result means

`search workspace_symbol` and `get implementations` can give an empty result
for two different reasons: no symbol matches, or the server does not have the
method. The result tells you which of the two it is. When no server has the
method, the result has the field `notSupportedReason` with one sentence that
names the request and the server. In each other case the result does not have
that field.

| Case | Result |
|---|---|
| A server has the method, and it finds matches | The matches. No `notSupportedReason`. |
| A server has the method, and it finds no match | An empty list. No `notSupportedReason`. |
| No server that runs has the method | An empty list, with `notSupportedReason`. |
| No server runs | An empty list. No `notSupportedReason`. |
| The request fails for a different reason, for example a timeout | An empty list. No `notSupportedReason`. |

`search workspace_symbol` asks each server that runs and advertises
`workspaceSymbolProvider`. The matches of all these servers go in one list.
Thus a workspace with Python and Go gets the Go symbols, also when `pylsp`
has no `workspace/symbol`. The text is:

```text
No language server that runs has workspaceSymbols. These servers run: gopls, pylsp.
```

`get implementations` keeps its cascade to the index layers when the server
of the file does not have `textDocument/implementation`. Thus a result can
have `notSupportedReason` together with locations from an index layer. The
field `sourceLayer` tells you which layer gave the locations. The text is:

```text
The language server pylsp does not have implementations.
```
