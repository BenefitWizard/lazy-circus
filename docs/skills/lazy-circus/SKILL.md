---
name: lazy-circus
description: >
  Expert guidance for Lazy Circus, a Haskell effect framework of Church-encoded
  free monads orchestrated by ScenarioProgram. Use for any LazyCircus / lazy-circus
  module or task about scenarios (ScenarioProgram, evalScript, runSafely, runAsync),
  scene effect scripts (DBScript, TelegramScript, AIScript, MailScript, HTTPScript
  and their tgScript / dbScript / aiScript / mailScript / httpScript wrappers),
  AI requests (mkAIRequest, AIParams, Conversation) and POML prompt templates
  (makePoml, .poml files), DB specifics (findLocked, withTransactionRLS), services
  (callService, makeServiceLib), runtime (DefaultPerformer, runAsyncWorkerPool),
  testing (runWithDefaultMocks, tgTest, TelegramTestScript, mkTextUpdate),
  or BDD feature specs (gherkinSpec, .feature files, StepDef, awaitObservation,
  Observation journal).
---

# Lazy Circus Skill

Use this skill when the task involves writing or reviewing Lazy Circus code, extending the
framework, or explaining how to use it correctly.

Detailed material lives in the `reference/` directory next to this file. Read the file(s)
matching the layer you are touching — everything else stays out of context.

**The references are self-sufficient**: every exported API is documented with its type
signature and usage examples, so you should never need to read library source files.
If a signature you need is genuinely missing from the references, do a POINT lookup
instead of opening source files:

```bash
# works in any stack project that depends on lazy-circus (library repo or consumer
# with lazy-circus as a git/path/hackage dep) — answers come from compiled interfaces,
# no source checkout needed. <package> = your local package name (in this repo: lazy-circus).
printf ':m +LazyCircus.Testing.Performer\n:t runWithAiMocks\n:i Mocks\n:q\n' \
  | stack ghci <package>:lib --ghci-options "-v0"
```

- `:t name` — exact type; `:i Name` — constructors, record fields, instances; `:browse Module` — every export
- always pass an explicit target (`<package>:lib`), otherwise `stack ghci` stops at an
  interactive main-module prompt when piped non-interactively
- LSP hover / goToDefinition also work when configured; prefer them over grep
- avoid raw source reading (`rg`, opening `.hs` files) — it wastes context and invites drift

The module map is in [reference/scenarios.md](reference/scenarios.md).

## Core Model

Lazy Circus works in four layers:

1. Scene language — one domain effect such as DB, Telegram, AI, Mail, or HTTP
2. Script — wrap one scene program into `Script` so scenarios can evaluate it
3. Scenario — orchestrate business flow in `ScenarioProgram`
4. Performer — interpret the abstract program in production or tests

Routing by intent:

- business orchestration → write `ScenarioProgram`
- one domain effect → write a scene script, wrapped via `tgScript` / `dbScript` / `aiScript` / `mailScript` / `httpScript`
- runtime behavior → change a performer
- new table integration → implement DB service instances
- long-lived background worker → register a service, call it via `callService`

## Reference Map

| If the task is about | Read |
|---|---|
| `ScenarioProgram`, `evalScript`, `runSafely`, `runAsync`, `runArbitraryIO`, architecture map, key modules | [reference/scenarios.md](reference/scenarios.md) |
| `DBScript`, transactions, row locking (`findLocked`), RLS (`withTransactionRLS`), update patch semantics | [reference/db.md](reference/db.md) |
| `TelegramScript`, file downloads, size gates (`downloadCheckedFile`) | [reference/telegram.md](reference/telegram.md) |
| `AIScript`, `AIRequest` / `AgentRequest`, `AIParams`, `Conversation`, tool-aware scripts | [reference/ai.md](reference/ai.md) |
| Prompt templates: `POML` AST, `.poml` files, `makePoml`, `parsePomlText` | [reference/poml.md](reference/poml.md) |
| `MailScript`, `HTTPScript` | [reference/mail-http.md](reference/mail-http.md) |
| `DefaultPerformer`, `DefaultApp`, pools, dispatch paths, async worker pool, teardown | [reference/runtime.md](reference/runtime.md) |
| Test performer, mocks, `TestConfig`, capture buffers (`readLog`, `readTgRequests`, ...), fake `Update`s, DB test setup | [reference/testing.md](reference/testing.md) |
| End-to-end bot tests: `tgTest`, `TelegramTestScript`, `waitFor*`, `Mailboxes` | [reference/tg-test.md](reference/tg-test.md) |
| BDD feature specs: `.feature` files, `gherkinSpec`, `StepDef` registries, the `Observation` journal, `awaitObservation`, `@blocked` | [reference/bdd.md](reference/bdd.md) |
| DB service instances, service registration, `makeServiceLib`, adding a new effect, integration pitfalls and checklist | [reference/extension.md](reference/extension.md) |
| Logging placement, WHAT-not-WHY, user-data ban, debug vs prod, `slog*` API | [reference/logging.md](reference/logging.md) |

Read more than one reference file when a task crosses layers.

## Global Rules

- `logInfo` / `logWarn` / `logError` / `logSensitive` in `ScenarioProgram`; `slog*` / `swithLogCtx` inside scene languages. Details and anti-patterns: [reference/logging.md](reference/logging.md).
- `runArbitraryIO` is a last-resort escape hatch: the `IO` runs for real in BOTH production and tests, cannot be mocked, and is invisible to automatic timing.
- Run `hpack` AND `hpack testing` before every build or test (two packages: the library and the `lazy-circus-testing` subpackage); never edit `exposed-modules` in `package.yaml` manually.
- Every exported function and type follows the repo Haddock contract style (see AGENTS.md).
- DB is never mocked: the root test suite runs against a real PostgreSQL database, while the `lazy-circus-testing` suite (including the BDD specs) is DB-free and passes with PostgreSQL stopped (details: [reference/testing.md](reference/testing.md), [reference/bdd.md](reference/bdd.md)).

Each reference file ends with a domain review checklist; consult the relevant one when reviewing changes.
