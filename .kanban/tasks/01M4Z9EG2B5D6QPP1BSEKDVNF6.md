---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4zdf2dd9zdsj7vn15s5ywb4
  text: 'Research: docs/tools.md gives these `get blastradius` parameters: `scope` (working, file, sha; default file), `file` (only for the scope file; also a glob), `symbol` (only for one path, not a glob), `sha` (only for the scope sha; a commit name or a `<from>..<to>` range; a name X selects the files that change from X to HEAD), `maxHops` (default 3). In ../skills, code-context/SKILL.md has the table row "The effect of a change", the rule "Before you change a symbol" and the verb snippet "// Impact". explore/SKILL.md has the same table row and step "4. Scope". skills/map is not changed (the card says so).'
  timestamp: 2026-10-15T09:14:35.309782+00:00
- actor: claude-code
  id: 01m4zdfwzzmxkge7tra0ckhx5g
  text: |-
    ### implement — changed
    - evidence: 2 files in ../skills — skills/code-context/SKILL.md (table row, new rule "Before a commit or a review", two new `getBlastradius` scope lines in the "// Impact" snippet), skills/explore/SKILL.md (table row, `scope: "working"` call in step 4). The old `file` examples stay. All new parameter names (`scope`, `sha`, `maxHops`) are in docs/tools.md. No validator rules match `.md`. No tests (the card says so).
    - next: commit in ../skills (subtask "Commit in ../skills" is open), then /review.

    ```
    step: implement
    outcome: changed
    evidence: ../skills/skills/code-context/SKILL.md, ../skills/skills/explore/SKILL.md
    task: ^ekdvnf6
    ```
  timestamp: 2026-10-15T09:15:02.527302+00:00
- actor: claude-code
  id: 01m4zdgqa6ah39azfnfcesxyr4
  text: |-
    ### commit — changed
    - evidence: a834cfa docs(skills): teach getBlastradius with the scopes working and sha ^ekdvnf6 (in ../skills, local, not pushed)
    - files: skills/code-context/SKILL.md, skills/explore/SKILL.md. No other file was changed in ../skills.
    - next: review
  timestamp: 2026-10-15T09:15:29.478859+00:00
- actor: claude-code
  id: 01m4zdjer0tstkegc2wpmzywcx
  text: |-
    ### review — clean
    - evidence: 0 findings. Scope: commit a834cfa (`HEAD~1..HEAD`) in /Users/wballard/github/swissarmyhammer/skills. No validator matches `.md` files, and the engine cannot run in that repository. Thus a manual review of the diff against the acceptance criteria. All five criteria pass. The parameter names `scope`, `sha`, `file`, `symbol` and `maxHops` are all in the `get blastradius` rows of `docs/tools.md`. The old examples with `file` stay. The new text is ASD-STE100.
    - next: none. The task moves to done.

    ```
    step: review
    outcome: clean
    evidence: 0 findings
    task: ^ekdvnf6
    ```
  timestamp: 2026-10-15T09:16:26.240179+00:00
- actor: claude-code
  id: 01m4zdjsq71hhsxnzmgxhzb6qz
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 files in ../skills
    - test: none — the user said skills get no tests
    - commit: a834cfa (in ../skills)
    - review: clean — 0 findings
  timestamp: 2026-10-15T09:16:37.479253+00:00
depends_on:
- 01M4Y6BF5YJ7BAWC2FRJANRD9H
position_column: done
position_ordinal: e080
title: 'Skills: teach getBlastradius with the scopes working and sha in ../skills'
---
## What

The task ^janrd9h gives `get blastradius` the `scope` parameter (`working`, `file`, `sha`) and the `sha` parameter. Update the skills in the sibling repository `../skills` (the `swissarmyhammer-skills` marketplace, Stencil templates that FoundationModelsSkills reads), so that agents use the new scopes. Do this task only after ^janrd9h is done. The parameter names must be the same as the names in `docs/tools.md` of this repository.

At the moment, the skills show only `getBlastradius({ file, symbol })`. Change these files in `../skills`:

- `skills/code-context/SKILL.md`:
  - The table row "The effect of a change" (near line 40): also name `getBlastradius({ scope: "working" })` for the changes that you made.
  - The rules list near line 95: add a rule. Before a commit or a review, `getBlastradius({ scope: "working" })` gives the callers that the changes in the working tree can affect. For a commit or a range, use `getBlastradius({ scope: "sha", sha: "HEAD~1" })`.
  - The verb snippet near line 119: add the two scope calls after the current `getBlastradius` line.
- `skills/explore/SKILL.md`:
  - The table row near line 31: the same change as in `code-context`.
  - Step "4. Scope — measure the blast radius" (near line 125): add `getBlastradius({ scope: "working" })` for the case where the change is already in the working tree.
- `skills/map/SKILL.md` (line 52): this skill finds the impact of one key file. Thus it does not change.

Write all the new text in ASD-STE100 Simplified Technical English, the same as the current text of the skills. Commit the change in the `../skills` repository, not in this repository.

This task is a documentation change only. It has no tests.

Subtasks:
- [x] Update `skills/code-context/SKILL.md`.
- [x] Update `skills/explore/SKILL.md`.
- [x] Commit in `../skills`.

## Acceptance Criteria
- [x] `skills/code-context/SKILL.md` and `skills/explore/SKILL.md` each show `getBlastradius({ scope: "working" })`.
- [x] `skills/code-context/SKILL.md` shows `getBlastradius({ scope: "sha", sha: ... })`.
- [x] The examples that exist at the moment, `getBlastradius({ file, symbol })` and `getBlastradius({ file, maxHops })`, stay in the skills, because the call with `file` stays valid.
- [x] Each parameter name in the new examples (`scope`, `sha`, `file`, `symbol`, `maxHops`) is a parameter of `get blastradius` in `docs/tools.md` of this repository.
- [x] The change is committed in `../skills`.

## Workflow
- No tests and no `/tdd` for this task. Change the skill text, then commit. #blastradius #docs