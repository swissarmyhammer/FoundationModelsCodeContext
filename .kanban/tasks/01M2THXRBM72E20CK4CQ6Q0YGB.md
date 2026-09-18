---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Two index passes can run at the same time and embed the same files twice
---
## What

`CodeContext.runOneIndexPass()` has three callers: the index loop task, the `nudgeWorkers` callback of the watcher, and `rebuildIndex(layer:)`. No caller waits for a pass that runs. After card `^jpfctny`, the first pass runs in the index loop task and can be long (minutes for a large repository with a real embedding model). A watcher nudge or a `rebuildIndex(layer:)` call during that pass starts a second `TreeSitterWorker.run` on the same dirty files.

The result is correct, because each file write is one transaction. But the second pass parses and embeds the same files again, and that doubles the load on the embedding model.

## The work

- Make `CodeContext` run one index pass at a time. A request during a pass must not start a second pass. It must make the pass run again after the current pass is complete (coalesce the requests).
- `rebuildIndex(layer:)` must still return only after a pass that started after the rebuild is complete.
- `stop()` must still cancel the pass and return promptly.
- Add a unit test with `GatedEmbedder` (`Tests/FoundationModelsCodeContextTests/Support/GatedEmbedder.swift`): a nudge during a gated first pass does not give a second `embed(_:)` call for the same chunks.

## Where it was found

Found during the work on `^jpfctny`. The fault existed before that card, but a short pass made it rare. #index