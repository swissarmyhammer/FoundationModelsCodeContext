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
runs one time as a maximum, so a failed installation cannot loop.

| Language(s) | Server | Auto-install command | Installer tool |
|---|---|---|---|
| Rust | `rust-analyzer` | `rustup component add rust-analyzer` | `rustup` |
| Go | `gopls` | `go install golang.org/x/tools/gopls@latest` | `go` |
| Python | `pylsp` | `pipx install python-lsp-server` | `pipx` |
| TypeScript / JavaScript / TSX | `typescript-language-server` | `npm install -g typescript-language-server typescript` | `npm` |
| PHP | `intelephense` | `npm install -g intelephense` | `npm` |
| Java | `jdtls` | `brew install jdtls` | `brew` |
| Swift | `sourcekit-lsp` | hint only — install Xcode or a Swift toolchain | — |
| C / C++ | `clangd` | hint only — install with your package manager | — |
| C# | `omnisharp` | hint only — install OmniSharp | — |

The last three are **hint-only**: no automatic installer is available for
them, because they need a full toolchain or their installations are not
reliable. A missing binary stays `.notFound` and shows its install hint.
This is the same behavior these servers had before auto-install existed.

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

When a request fails, the log shows the server, the request, and the code
and the message of the server error. The log has one line for each
(server, request) pair, not one line for each symbol.

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
