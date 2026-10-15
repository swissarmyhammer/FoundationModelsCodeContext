---
assignees:
- claude-code
depends_on:
- 01M4Y6BF5YJ7BAWC2FRJANRD9H
position_column: todo
position_ordinal: '8280'
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
- [ ] Update `skills/code-context/SKILL.md`.
- [ ] Update `skills/explore/SKILL.md`.
- [ ] Commit in `../skills`.

## Acceptance Criteria
- [ ] `skills/code-context/SKILL.md` and `skills/explore/SKILL.md` each show `getBlastradius({ scope: "working" })`.
- [ ] `skills/code-context/SKILL.md` shows `getBlastradius({ scope: "sha", sha: ... })`.
- [ ] The examples that exist at the moment, `getBlastradius({ file, symbol })` and `getBlastradius({ file, maxHops })`, stay in the skills, because the call with `file` stays valid.
- [ ] Each parameter name in the new examples (`scope`, `sha`, `file`, `symbol`, `maxHops`) is a parameter of `get blastradius` in `docs/tools.md` of this repository.
- [ ] The change is committed in `../skills`.

## Workflow
- No tests and no `/tdd` for this task. Change the skill text, then commit. #blastradius #docs