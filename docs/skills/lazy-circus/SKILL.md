---
name: lazy-circus
description: >
  Expert guidance for working with Lazy Circus — a Haskell effect framework based on
  Church-encoded free monads and ScenarioProgram orchestration. Use this skill whenever
  the user mentions LazyCircus, lazy-circus, ScenarioProgram, Script, DBScript,
  TelegramScript, AIScript, MailScript, HTTPScript, evalScript, tgScript, mailScript,
  aiScript, httpScript, DefaultPerformer, DBScriptDef, HasLogLang, or asks how to write
  scenarios, add new effects, define DB service instances, or test Lazy Circus programs.
---

# Lazy Circus Skill

Use this skill when the task involves writing or reviewing Lazy Circus code, extending the
framework, or explaining how to use it correctly.

The detailed material now lives in the `reference/` directory next to this file. Start here,
then read the specific reference file for the layer you are touching.

## Core Model

Lazy Circus works in four layers:

1. Scene language layer
   One domain effect such as DB, Telegram, AI, Mail, or HTTP.
2. Script layer
   Wrap one scene program into `Script` so scenarios can evaluate it.
3. Scenario layer
   Orchestrate business flow in `ScenarioProgram`.
4. Performer layer
   Interpret the abstract program in production or tests.

Default routing:

- business orchestration -> write `ScenarioProgram`
- one domain effect -> write a scene script
- runtime behavior -> change a performer
- new table integration -> implement DB service instances

## Read Reference Material When

| If the task is about | Read |
|---|---|
| `ScenarioProgram`, `evalScript`, `runSafely`, `runAsync`, scenario logging, extra context, or the architecture map | [reference/scenarios.md](reference/scenarios.md) |
| DB/Telegram/AI/Mail/HTTP DSL operations, smart constructors, scene-level logging, or top-level wrappers like `tgScript` / `mailScript` / `aiScript` / `httpScript` | [reference/effects.md](reference/effects.md) |
| `DefaultPerformer`, `evalScriptDefault`, environment projection, async queue behavior, test interpreter behavior, mocks, or DB test setup | [reference/runtime-testing.md](reference/runtime-testing.md) |
| DB service instances, service registration, adding a new public effect, integration checklists, or the detailed pitfalls/review checklist | [reference/extension.md](reference/extension.md) |

Read more than one reference file when a task crosses layers.

## High-Signal Rules

- Use `logInfo`, `logWarn`, `logError`, and `logSensitive` in `ScenarioProgram`.
- Use `slogInfo`, `slogWarn`, `slogError`, `slogSensitive`, and `swithLogCtx` inside scene languages.
- Wrap scene programs before `evalScript`:
  - Telegram -> `tgScript "bot-name" ...`
   - Mail -> `mailScript ...`
   - AI -> `aiScript ...` (empty tools) or `aiScriptWithAll ...` / `aiScriptWith tools ...` (TH-generated, with tools)
   - DB -> `DBScriptDef db mode ...`
   - HTTP -> `httpScript baseUrl ...`
- `AIScriptDef` takes a `[ToolDescription]` as its first argument; `aiScript` passes `[]` for backward compatibility.
- Use `callService` to invoke registered services from `ScenarioProgram`.
- `ScenarioProgram` has two type parameters: `ScenarioProgram script serviceLib a`.
- `DefaultApp` is parameterized by the service library type: `DefaultApp serviceLib`. Use `NoServiceLib` when no services are needed.
- `create` and `createAsIs` return `Maybe row`.
- `ReadOnly` forbids write operations.
- Tests in this repository use a real PostgreSQL database.
- Test `runAsync` captures scheduled scenarios instead of executing them.
- Always run `hpack` before build or tests.
- Do not manually edit `exposed-modules` in `package.yaml`.
- Every exported function, type, typeclass, and non-trivial instance follows the repo Haddock style.
- Use `makeServiceLib` (from `LazyCircus.App.Service.TH`) to generate service libraries from request/response/tool-spec triples.

## Inspect First

- `src/LazyCircus/Scenario.hs`
- `src/LazyCircus/Script.hs`
- `src/LazyCircus/Performer.hs`
- `src/LazyCircus/Performer/Default.hs`
- the relevant `src/LazyCircus/Scene/*` module for the domain you are touching
- `src/LazyCircus/Testing/Performer.hs` for tests
- `src/LazyCircus/DB/Service.hs` plus the concrete table module for DB integration work
- `src/LazyCircus/App/Service.hs` for service registration
- `src/LazyCircus/App/Service/TH.hs` for TH-generated service libraries and tool plumbing

Prefer LSP navigation for Haskell modules when possible.

## Common Mistakes

- Writing orchestration logic inside a scene DSL instead of `ScenarioProgram`.
- Calling `logInfo` inside a scene language or `slogInfo` inside `ScenarioProgram`.
- Forgetting to wrap a scene script into `Script` before `evalScript`.
- Treating DB `create` helpers as if they returned a plain row instead of `Maybe`.
- Assuming tests execute async work or fake DB behavior.
- Adding a new public effect without the supporting `Script` dispatch and stable public facade when needed.
- Using `makeServiceLib` with `(Name, Name)` pairs instead of `(Name, Name, [(Name, String, String)])` triples.
- Forgetting `FromJSON`/`ToJSON` instances on request/response types when tool specs are provided to `makeServiceLib`.

## Review Checklist

1. Is the code in the correct layer?
2. Are logging APIs used at the correct layer?
3. Are exported APIs documented with Haddock contracts?
4. If DB tables changed, are the service instances complete?
5. If a new effect was added, was dispatch updated everywhere?
6. Are tests aligned with real async and DB behavior?
7. Was `hpack` run before build or test?
