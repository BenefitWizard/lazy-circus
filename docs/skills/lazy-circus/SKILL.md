---
name: lazy-circus
description: >
  Expert guidance for working with Lazy Circus — a Haskell effect framework based on
  Church-encoded free monads and ScenarioProgram orchestration. Use this skill whenever
  the user mentions LazyCircus, lazy-circus, ScenarioProgram, Script, DBScript,
  TelegramScript, AIScript, MailScript, HTTPScript, evalScript, tgScript, mailScript,
  aiScript, httpScript, sendDocument, askContinuing, solveWithAgent,
  solveWithAgentContinuing, AgentRequest, Conversation, DefaultPerformer, DBScriptDef,
  findLocked, findAllLocked, LockSpec, HasLogLang, tgTest, TelegramTestScript, waitForReply, waitForMatching, OutgoingMessage,
  Mailboxes, UpdateFactory, mkTextUpdate, or asks how to write scenarios, add new effects,
  define DB service instances, or test Lazy Circus programs (including end-to-end Telegram
  bot tests).
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
| `DefaultPerformer`, `evalScriptDefault`, environment projection, async queue behavior, test interpreter behavior, mocks, DB test setup, end-to-end Telegram bot tests (`tgTest` / `TelegramTestScript`), or fake Telegram `Update`s | [reference/runtime-testing.md](reference/runtime-testing.md) |
| DB service instances, service registration, adding a new public effect, integration checklists, or the detailed pitfalls/review checklist | [reference/extension.md](reference/extension.md) |
| Where to place logs, what to log vs what not to log, debug vs prod, context propagation, or logging anti-patterns | [reference/logging.md](reference/logging.md) |

Read more than one reference file when a task crosses layers.

## High-Signal Rules

- Use `logInfo`, `logWarn`, `logError`, and `logSensitive` in `ScenarioProgram`.
- Use `slogInfo`, `slogWarn`, `slogError`, `slogSensitive`, and `swithLogCtx` inside scene languages.
- Log WHAT happened and WHAT decision was made. Not WHY — the "why" lives in the code.
- Put traceability context (IDs, keys) in `withLogContext` / `withLogEntry`, not in the log message string.
- Never log user data (message text, LLM output, file content). Use IDs in structured context instead.
- Timing is automatic (`timedAndLog` in performers). Do not log start/finish manually.
- `logSensitive` / `slogSensitive` = debug only. Everything else is visible in production.
- Wrap scene programs before `evalScript`:
  - Telegram -> `tgScript "bot-name" ...`
   - Mail -> `mailScript ...`
   - AI -> `aiScript ...` (empty tools) or `aiScriptWithAll ...` / `aiScriptWith tools ...` (TH-generated, with tools)
   - DB -> `DBScriptDef db mode ...`
   - HTTP -> `httpScript baseUrl ...`
- `AIScriptDef` takes a `[ToolDescription]` as its first argument; `aiScript` passes `[]` for backward compatibility.
- For multi-turn AI, thread a `Conversation` with `askContinuing` / `solveWithAgentContinuing`. Stateless `ask` / `solveWithAgent` inject `emptyConversation` and discard the transcript.
- A `Conversation` never holds a `Chat.System` message; build it only via `emptyConversation` or `conversationFromTurns`.
- Use `callService` to invoke registered services from `ScenarioProgram`.
- `ScenarioProgram` has two type parameters: `ScenarioProgram script serviceLib a`.
- `DefaultApp` is parameterized by the service library type: `DefaultApp serviceLib`. Use `NoServiceLib` when no services are needed.
- `create` and `createAsIs` return `Maybe row`.
- `ReadOnly` forbids write operations.
- `findLocked` / `findAllLocked` acquire a row lock (`FOR UPDATE` family) via a `LockSpec`; they MUST run inside `withTransaction` (locks are released at COMMIT/ROLLBACK). `WaitNoWait` surfaces contention as a thrown `SqlError`; `WaitSkipLocked` makes an empty result ambiguous. They are allowed in `ReadOnly` and reuse `HasReadService` — no extra instances.
- Tests in this repository use a real PostgreSQL database.
- Test `runAsync` with `tcAsync = Mocked` (the default) captures scheduled scenarios instead of executing them; `tcAsync = Real` spawns the worker through the same test interpreter so its side effects land in the usual capture buffers (mailbox / `readTgRequests`), and `readScheduledScenarios` stays empty.
- Always run `hpack` before build or tests.
- Do not manually edit `exposed-modules` in `package.yaml`.
- Every exported function, type, typeclass, and non-trivial instance follows the repo Haddock style.
- Use `makeServiceLib` (from `LazyCircus.App.Service.TH`) to generate service libraries from request/response/tool-spec triples.
- `tgTest` (from `LazyCircus.Testing.TgTest`) drives the bot's own `Update -> IO ()` handler via `runHeadlessBot`; `buildAction` MUST wire the test performer (`runWithMocks`) against the same `Mocks` the runner hands it.
- The `tgTest` DSL's `waitFor*` ops block deterministically via STM `retry` on the `outgoingMailbox`; never replace them with polling. Fail with `TgTestTimeout` on timeout, `TgTestGuardFailed` on a failed `guard`.
- Every Telegram `sendMessage` / `sendDocument` / `setMessageReaction` / `editMessageText` publishes an `OutgoingMessage` (tagged with `OutgoingKind`) to the STM mailbox; `sendMessage`/`sendDocument` responses are stamped with a fresh incremental `MessageId`.
- In the `tgTest` DSL, the message-sending ops (`sendMessage` / `sendMessageIn` / `sendMessageByUser` / `sendFile` / `sendFileByUser`) return `(UpdateId, MessageId)` so the message id can be threaded into `waitForReaction` / `sendKeypress`; `sendKeypress*` return just `UpdateId`.
- Use `LazyCircus.Testing.Updates` (`mkTextUpdate`, `mkCallbackQueryUpdate`, `UpdateFactory`) to build fake `Update`s for synchronous handler tests; use `tgTest` for end-to-end dialog tests.

## Inspect First

- `src/LazyCircus/Scenario.hs`
- `src/LazyCircus/Script.hs`
- `src/LazyCircus/Performer.hs`
- `src/LazyCircus/Performer/Default.hs`
- `src/LazyCircus/AI.hs` and `src/LazyCircus/AI/Conversation.hs` for AI request types, the agent loop, and the `Conversation` transcript
- the relevant `src/LazyCircus/Scene/*` module for the domain you are touching
- `src/LazyCircus/Testing/Performer.hs` for mock-backed scenario/script tests
- `src/LazyCircus/Testing/TgTest.hs` for the end-to-end `tgTest` runner and `TelegramTestScript` DSL
- `src/LazyCircus/Testing/Updates.hs` for fake Telegram `Update` factories
- `src/LazyCircus/DB/Service.hs` plus the concrete table module for DB integration work
- `src/LazyCircus/App/Service.hs` for service registration
- `src/LazyCircus/App/Service/TH.hs` for TH-generated service libraries and tool plumbing

Prefer LSP navigation for Haskell modules when possible.

## Common Mistakes

- Writing orchestration logic inside a scene DSL instead of `ScenarioProgram`.
- Calling `logInfo` inside a scene language or `slogInfo` inside `ScenarioProgram`.
- Putting user data (query text, AI response, email body) into log message strings instead of structured context.
- Logging manual start/finish timing when `timedAndLog` already handles it in the performer.
- Explaining reasoning in log text instead of stating the observable decision.
- Forgetting to wrap a scene script into `Script` before `evalScript`.
- Treating DB `create` helpers as if they returned a plain row instead of `Maybe`.
- Calling `findLocked` / `findAllLocked` outside `withTransaction` and expecting a held lock — Postgres auto-commits the statement, so the lock is released immediately (a no-op). Always wrap locking reads in `withTransaction`.
- Building a `Conversation` with a leading `Chat.System` message, or pattern-matching on the unexported `Conversation` constructor instead of using `emptyConversation` / `conversationFromTurns`.
- Assuming tests execute async work or fake DB behavior.
- Adding a new public effect without the supporting `Script` dispatch and stable public facade when needed.
- Using `makeServiceLib` with `(Name, Name)` pairs instead of `(Name, Name, [(Name, String, String)])` triples.
- Forgetting `FromJSON`/`ToJSON` instances on request/response types when tool specs are provided to `makeServiceLib`.
- Writing a custom Telegram-test wait that polls the mailbox instead of using the built-in `waitFor*` / `waitForMatching` (which block on STM `retry` and wake deterministically).
- In `tgTest`, wiring `buildAction` against a different `Mocks` than the one the runner supplied, so replies never reach the mailbox the DSL observes.
- Asserting on Telegram side effects from `runAsync` during tests — with `tcAsync = Mocked` (default) `runAsync` only captures scheduled scenarios (assert via `readScheduledScenarios` / `mbScheduledScenarioCount`); with `tcAsync = Real` the spawned worker's side effects DO appear in the mailbox, so that assertion no longer holds.
- Expecting `waitForFile` to return the bot's real `FileId` — the mailbox capture returns a stable placeholder suitable only for ordering assertions.

## Review Checklist

1. Is the code in the correct layer?
2. Are logging APIs used at the correct layer?
3. Do scenario logs capture decisions at branch points?
4. Is user data kept out of log text (only IDs in structured context)?
5. Are exported APIs documented with Haddock contracts?
6. If DB tables changed, are the service instances complete?
7. If locking reads (`findLocked` / `findAllLocked`) are used, are they inside `withTransaction` and is the `WaitNoWait` / `WaitSkipLocked` ambiguity handled?
8. If a new effect was added, was dispatch updated everywhere?
9. Are tests aligned with real async and DB behavior?
10. Was `hpack` run before build or test?
