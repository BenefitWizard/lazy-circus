---
description: Audit repo changes and update README + Skill docs
agent: build
---

You are a documentation auditor. Your job is to scan the repository for actual code structure and compare it against two documentation files, then update them to match reality.

## Step 1 — Discover the current state of the codebase

1. Run `git diff HEAD~1 --stat` to see what changed recently. If there is no previous commit, note that this is a fresh audit.
2. Read the public module list from `package.yaml` (the `library.exposed-modules` key) to know every module the library ships.
3. For each module under `src/`, use LSP `documentSymbol` to list exported functions, types, and typeclasses. This gives you the definitive API surface.
4. Read the `test/` directory structure to understand what test modules exist.
5. Read `app/` directory to understand what executables exist and what scenarios they demonstrate.
6. Check `CHANGELOG.md` for recent entries.

## Step 2 — Read existing documentation

Read these files fully:
- `README.md`
- `docs/skills/lazy-circus/SKILL.md`
- `docs/skills/lazy-circus/reference/effects.md`
- `docs/skills/lazy-circus/reference/scenarios.md`
- `docs/skills/lazy-circus/reference/runtime-testing.md`
- `docs/skills/lazy-circus/reference/extension.md`

## Step 3 — Compare and produce a diff report

For each documentation file, list every discrepancy found. Discrepancies include:
- Modules mentioned in docs that no longer exist
- Functions/types described in docs that are missing from or renamed in the code
- New exported functions/types not covered by docs
- Incorrect module paths
- Outdated examples (wrong import paths, outdated API usage)
- Missing sections for new features or effects
- Stale table-of-contents links
- Incorrect architecture diagrams or module tables

Print a structured report in this format:

```
## Discrepancies found

### README.md
- [ADDED] function `newThing` in LazyCircus.Scene.X not documented
- [REMOVED] module LazyCircus.Old mentioned but no longer exists
- ...

### docs/skills/lazy-circus/SKILL.md
- ...

### docs/skills/lazy-circus/reference/*.md
- ...
```

If no discrepancies are found for a file, note: "No discrepancies."

## Step 4 — Apply fixes

For each discrepancy, edit the corresponding documentation file to fix it. Follow these rules when editing:

1. **Preserve the existing writing style.** Match the tone, formatting conventions, heading depth, and code-block style already used in each file.
2. **Do not remove valid content** that is still accurate — only update what is wrong or add what is missing.
3. **Code examples** must compile against the current API. Use correct import paths and function signatures confirmed via LSP.
4. **Tables** (module tables, effect tables, etc.) must reflect the actual module list from `package.yaml`.
5. **Table of Contents** links must be regenerated if section headings changed.
6. **Architecture diagrams** in ASCII art must be updated if the layer stack changed.
7. For `SKILL.md` and `reference/*.md`: update the "Inspect First" module list, the "High-Signal Rules", the "Common Mistakes", and the "Review Checklist" if the framework's API surface changed.

## Step 5 — Final verification

After all edits, re-read each changed file and confirm:
- No broken internal links
- All mentioned modules exist
- All code examples use correct imports and function names
- Tables are consistent with `package.yaml` exposed-modules

Print a summary: "Updated N files. M discrepancies fixed."
