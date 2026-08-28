# Lazy Circus Reference: Testing

Read this when:

- writing scenario/script tests with the test performer (`runWithMocks`, `runWithDefaultMocks`, `runScenarioProgram`)
- reading captured side effects (`readLog`, `readTgRequests`, `readOutgoingMailbox`, `readAiRequests`, ...)
- switching sub-languages to `Real` mode via `TestConfig`
- building fake Telegram `Update`s (`LazyCircus.Testing.Updates`)

For end-to-end tests that drive the bot's own update handler (routing, dialog state,
inline keyboards), see [tg-test.md](tg-test.md).

## Contents

- Shared-Runner Architecture
- Key Types
- Main Helpers
- AI Mocks (Canned Completions)
- Mocked Sub-Language Runners
- Mock Behavior Summary
- Typical Test Pattern
- DB Integration Tests
- Verifying Async Work
- Debugging: Where Did My Logs Go?
- Verifying Log Context
- Verifying Telegram Capture
- Configurable TestPerformer
- Fake Telegram Updates
- Review Checklist

## Shared-Runner Architecture

Module: `LazyCircus.Testing.Performer`

The test runtime is not a separate reimplementation of scenario semantics. It keeps the same
shared-runner architecture as production:

- `ScenarioProgram` still runs through the normal scenario interpreter machinery
- top-level `Script` dispatch still chooses DB, Telegram, Mail, AI, and HTTP branches the same way
- environment projection still happens through wrappers like `AppWithConnection` and `AppWithBotEnv`

The main difference is the capability layer behind that runner. By default (via `defaultTestConfig`),
all mockable sub-languages are mocked:

- DB capability checks out a real connection from the app's pool for each DB script (always real — no mock)
- Telegram capability is replaced with capture-oriented mocks (`tcTelegram = Mocked`)
- Mail capability reuses real mail construction but captures sends (`tcMailSend = Mocked`)
- AI capability uses a transport-level mock with FIFO canned responses (`tcAI = Mocked`)
- HTTP capability executes real servant-client requests via the configured manager and base URL (always real)
- async capability captures scheduled scenarios instead of executing them (`tcAsync = Mocked`, the default); with `tcAsync = Real` it spawns the scenario on a background thread through the same test interpreter
- logging capability captures structured entries instead of draining the production queue

Each mockable sub-language (Telegram, AI, Mail-send, async) can be switched to `Real` mode individually via
`TestConfig` — see [Configurable TestPerformer](#configurable-testperformer) below.

This means tests exercise the same orchestration path as production while swapping effectful
capabilities at the edges.

## Key Types

| Type | Purpose |
|---|---|
| `Mocks serviceLib` | collected mock state (Tg requests, mails, logs, async tasks) |
| `TgMock` | Telegram mock with configurable response queue, staged canned downloads, and an STM `outgoingMailbox` |
| `OutgoingMessage` | one captured outgoing Telegram side effect (kind, chat id, text, message id, reply markup) |
| `OutgoingKind` | tag on `OutgoingMessage`: `OutSendMessage` / `OutSendDocument` / `OutSetReaction` / `OutEditMessage` / `OutDeleteMessage` |
| `MailMock` | Mail mock for capturing sent mails |
| `Mode` | runtime mode for a sub-language: `Mocked` or `Real` |
| `TestConfig` | per-sub-language mode selection (`tcTelegram`, `tcAI`, `tcMailSend`, `tcAsync`) |
| `EnvWithMocks serviceLib` | environment extended with mock state and `TestConfig` |
| `TestInterpreter serviceLib a` | the test-performer monad |
| `OnSendMessageRequest` | callback type for custom Telegram send handling |

## Main Helpers

| Function | Purpose |
|---|---|
| `makeMocks` | allocate a fresh mock state (including an empty `outgoingMailbox`) |
| `runWithMocks` | run with caller-supplied app and mocks (uses `defaultTestConfig`: all-mocked) |
| `runWithDefaultMocks` | allocate mocks and run (uses `defaultTestConfig`: all-mocked) |
| `runWithConfig` | run with explicit `TestConfig` and caller-supplied mocks |
| `runWithDefaultConfig` | allocate mocks and run with explicit `TestConfig` |
| `runInsideWithConfig` | run inside `RIO DefaultApp` with explicit `TestConfig` and caller-supplied mocks |
| `runInsideWithDefaultConfig` | run inside `RIO DefaultApp` with explicit `TestConfig` after allocating fresh mocks |
| `runScenarioProgram` | execute a `ScenarioProgram Script` in `TestInterpreter` |
| `runScript` | execute one top-level `Script` |
| `runTestInterpreter` | unwrap a `TestInterpreter` action into the underlying `RIO (EnvWithMocks serviceLib)` |
| `readTgRequests` | read captured immediate `sendMessage` requests (legacy `SomeRef` log) |
| `readScheduledTgRequests` | read captured scheduled Telegram sends |
| `readOutgoingMailbox` | drain and return every `OutgoingMessage` still in the STM mailbox (destructive) |
| `readLog` | read captured log payloads |
| `readLogWithContext` | read contextualized log messages |
| `readSentMails` | read outgoing mails |
| `readAiRequests` | read captured AI chat-completion requests (Mocked mode only) |
| `readScheduledScenarios` | read captured async scenario requests |

Signatures (module `LazyCircus.Testing.Performer`; `sl` = `serviceLib`):

```haskell
makeMocks                 :: IO (Mocks sl)
runWithMocks              :: DefaultApp sl -> Mocks sl -> TestInterpreter sl a -> IO a
runWithDefaultMocks       :: DefaultApp sl -> TestInterpreter sl a -> IO (Mocks sl, a)
runWithConfig             :: DefaultApp sl -> TestConfig -> Mocks sl -> TestInterpreter sl a -> IO a
runWithDefaultConfig      :: DefaultApp sl -> TestConfig -> TestInterpreter sl a -> IO (Mocks sl, a)
runInsideWithConfig       :: TestConfig -> Mocks sl -> TestInterpreter sl a -> RIO (DefaultApp sl) a
runInsideWithDefaultConfig:: TestConfig -> TestInterpreter sl a -> RIO (DefaultApp sl) (Mocks sl, a)
runScenarioProgram        :: ScenarioProgram Script sl a -> TestInterpreter sl a
runScript                 :: Script a -> TestInterpreter sl a
runTestInterpreter        :: TestInterpreter sl a -> RIO (EnvWithMocks sl) a

readTgRequests            :: Mocks sl -> IO [WithImportance SendMessageRequest]
readScheduledTgRequests   :: Mocks sl -> IO [SendMessageRequest]
readOutgoingMailbox       :: Mocks sl -> IO [OutgoingMessage]      -- destructive drain
readLog                   :: Mocks sl -> IO [AppLogMsg]
readLogWithContext        :: Mocks sl -> IO [AppLogMsgWithContext]
readSentMails             :: Mocks sl -> IO [Mail]
readScheduledScenarios    :: Mocks sl -> IO [ScenarioProgram Script sl ()]
```

Also useful for custom harnesses:

- `runInsideWithMocks` and `runInsideWithDefaultMocks` run tests inside `RIO DefaultApp`
- AI mocks (`runWithAiMocks`, `runInsideWithAiMocks`, `makeMocksWithAi`, `createAiMock`, `readAiRequests`) — signatures and a canned-completion recipe in [AI Mocks](#ai-mocks-canned-completions)
- `runWithConfigEngine` is the shared engine beneath `runWithConfig` / `runWithMocks`; it awaits in-flight `tcAsync = Real` workers and drains queued logs before returning
- `discardMocks` drops the collected capture state when only the result matters
- `createTgMock`, `createSimpleTgMock`, `createSimpleMailMock`, and `addTgDownloads` (stage canned file downloads by `FileId` for Mocked `getFile` / `downloadFile`) help build custom mock setups; `createTgMock` takes the staged downloads as its third argument

## AI Mocks (Canned Completions)

All helpers live in `LazyCircus.Testing.Performer` (source: `src/LazyCircus/Testing/Performer.hs`);
the canned-response type comes from `OpenAI.V1.Chat.Completions` (import qualified as `Chat`).

```haskell
-- | Build an AI mock with a queue of canned completions (consumed FIFO) and an empty request log.
-- POST-CONTRACT: responses are consumed FIFO by the mocked transport.
createAiMock       :: [Chat.ChatCompletionObject] -> IO AiMock
createSimpleAiMock :: IO AiMock                        -- equivalent to createAiMock []

-- | Fresh 'Mocks' with the given responses queued FIFO in its 'aiMock'.
makeMocksWithAi :: [Chat.ChatCompletionObject] -> IO (Mocks serviceLib)

-- | runWithDefaults-style runner whose fresh mocks are pre-seeded with canned responses.
runWithAiMocks :: App.DefaultApp serviceLib -> [Chat.ChatCompletionObject]
               -> TestInterpreter serviceLib a -> IO (Mocks serviceLib, a)

-- | Same as runWithAiMocks, but inside RIO DefaultApp (app comes from ask).
runInsideWithAiMocks :: [Chat.ChatCompletionObject] -> TestInterpreter serviceLib a
                     -> RIO (App.DefaultApp serviceLib) (Mocks serviceLib, a)

-- | Captured rendered requests, earliest-first. Only meaningful when tcAI = Mocked.
readAiRequests :: Mocks serviceLib -> IO [Chat.CreateChatCompletion]

-- | Fallback completion with no choices; produced when the response queue is drained.
emptyCompletion :: Chat.ChatCompletionObject
```

Semantics:

- each transport call (`ask` / `solveWithAgent`; one dequeue per agent-loop iteration) takes the
  **next canned response FIFO** from the shared queue in `Mocks.aiMock`
- a **drained or never-seeded** queue yields `emptyCompletion` (zero choices) → the production
  decode path turns that into `Nothing`
- every rendered request is captured into `readAiRequests` regardless of queue state

### Building a canned `Chat.ChatCompletionObject`

The library exports no smart constructor — tests define one locally. Minimal helper returning a
single Assistant choice (verbatim shape of `mockCompletion` in `test/AiMockSpec.hs`):

```haskell
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.Usage (Usage (..))
import RIO
import RIO.Vector qualified as V

-- | One-choice assistant completion carrying the given content text.
mockCompletion :: Text -> Chat.ChatCompletionObject
mockCompletion contentText =
    Chat.ChatCompletionObject
        { Chat.id = "test-id"
        , Chat.choices =
            V.fromList
                [ Chat.Choice
                    { finish_reason = "stop"
                    , index = 0
                    , message =
                        Chat.Assistant
                            { Chat.assistant_content = Just contentText
                            , Chat.refusal = Nothing
                            , Chat.name = Nothing
                            , Chat.assistant_audio = Nothing
                            , Chat.tool_calls = Nothing   -- Just calls to drive an agent loop
                            , Chat.extra = Nothing
                            }
                    , Chat.logprobs = Nothing
                    }
                ]
        , Chat.created = 0
        , Chat.model = "test-model"
        , Chat.reasoning_effort = Nothing
        , Chat.service_tier = Nothing
        , Chat.system_fingerprint = Nothing
        , Chat.object = "chat.completion"
        , Chat.usage = Usage 0 0 0 Nothing Nothing
        }
```

Notes:

- the defining module needs `{-# LANGUAGE DuplicateRecordFields #-}` once other records with clashing
  field names are imported (field access stays `Chat.`-qualified)
- decode path reads `choices !? 0 → message → assistant_content`; JSON-typed scenarios parse that
  text as their result value, so stage valid JSON when the script decodes to `Value`
- `tool_calls = Just ...` makes `solveWithAgent` continue its tool loop — seed one further canned
  completion per expected iteration, finishing with a no-tool-calls choice; building tool calls needs
  `OpenAI.V1.ToolCall` (see the full two-parameter `mockCompletion` in `test/AiMockSpec.hs`)
- all-zero `usage` is fine; nothing asserts on token counts by default

### Example: scenario test with staged AI replies

Mirrors `test/AiMockSpec.hs` ("ask returns staged response through test performer"):

```haskell
import LazyCircus.AI (mkAIRequest)
import LazyCircus.Scenario (evalScript)
import LazyCircus.Scene.AI qualified as Scene (ask)
import LazyCircus.Script (Script (..))
import LazyCircus.Testing.Performer (readAiRequests, runScenarioProgram, runWithAiMocks)

it "answers via mocked AI" $ \app -> do
    let script :: Script (Maybe Value) =
            AIScriptDef [] (Scene.ask (mkAIRequest ["Calculate 2+2"] ["You are a calculator."]))
    (mocks, result) <-
        runWithAiMocks app [mockCompletion "{\"a\":4}"] $
            runScenarioProgram (evalScript script)
    result `shouldBe` Just (object ["a" .= (4 :: Int)])
    captured <- readAiRequests mocks
    length captured `shouldBe` 1
```

## Mocked Sub-Language Runners

These run one sub-language in isolation with mock logging:

| Function | Scope |
|---|---|
| `runDBWithMockLogging` | DB script with captured logs |
| `runTelegramScript` | Telegram script with mode-aware dispatch (Mocked = mailbox capture, Real = TG.* API) |

## Mock Behavior Summary

The `tcXxx` column shows which `TestConfig` field controls each sub-language. `Mocked` (default)
captures side effects; `Real` delegates to production implementations without capturing.

| Effect | `TestConfig` field | Mocked behavior (default) | Real behavior |
|---|---|---|---|
| Telegram `sendMessage` | `tcTelegram` | captures `WithImportance SendMessageRequest` in the `SomeRef` log (`readTgRequests`) AND publishes an `OutSendMessage` to the STM `outgoingMailbox` carrying a fresh incremental `MessageId`; returns the canned/default response stamped with that id | delegates to `TG.sendMessage` via `timedAndLog`; mailbox/request log stay empty |
| Telegram `sendDocument` | `tcTelegram` | publishes an `OutSendDocument` to the `outgoingMailbox` (with a fresh incremental `MessageId`) and returns the mock `defaultResponse` stamped with that id; not added to the `readTgRequests` log | delegates to `TG.sendDocument` via `timedAndLog` |
| Telegram `setMessageReaction` | `tcTelegram` | publishes an `OutSetReaction` to the `outgoingMailbox` carrying the target `MessageId` | delegates to `TG.setMessageReaction` via `timedAndLog` |
| Telegram `editMessageText` | `tcTelegram` | publishes an `OutEditMessage` to the `outgoingMailbox`; still always returns `Nothing` | delegates to `TG.editMessageText` via `timedAndLog` (returns real response) |
| Telegram `deleteMessage` | `tcTelegram` | publishes an `OutDeleteMessage` to the `outgoingMailbox` carrying the target `MessageId` | delegates to `TG.deleteMessage` via `timedAndLog` |
| Telegram `setBotCommands` / `answerCallbackQuery` | `tcTelegram` | no-op (return unit) | delegates to `TG.*` via `timedAndLog` |
| Telegram scheduled sends | `tcTelegram` | captured in a separate `SomeRef` list (`readScheduledTgRequests`) | delegates to `TG.scheduleMessages` via `timedAndLog` |
| Telegram missing bot | `tcTelegram` | throws `NoBotConfigured` exactly like production dispatch | same |
| Telegram `getBotName` | — (always real) | returns the supplied bot name | same |
| Telegram `getFile` / `downloadFile` | `tcTelegram` | Mocked: serve staged canned downloads by `FileId` (third `createTgMock` argument / `addTgDownloads`); `getFile` reports the canned byte length as `fileFileSize`, `downloadFile` returns the staged bytes; an unstaged `FileId` throws | Real: delegates to `TG.getFile` / `TG.downloadFile` via `timedAndLog` |
| Mail `sendMail` | `tcMailSend` | captures mail values in `readSentMails` | delegates to `Mail.sendMail` (real SMTP) via `timedAndLog`; capture stays empty |
| Mail `makeMail` | — (always real) | uses real mail construction from env creds | same |
| AI `ask` / `askContinuing` / `solveWithAgent` / `solveWithAgentContinuing` | `tcAI` | transport-level intercept: overrides `aiMethodsL` with `buildMockAiMethods`, which captures every rendered request (`readAiRequests`) and dequeues FIFO canned `ChatCompletionObject` responses; empty queue yields `emptyCompletion` → `Nothing` | delegates to real `askAIContinuing` / `solveWithAgentLoopContinuing` WITHOUT overriding `aiMethodsL` (real OpenAI client); `readAiRequests` stays empty |
| HTTP `runClient` | — (always real) | real execution via servant-client against target base URL | same |
| DB | — (always real) | runs against a real DB (one pooled connection per script) | same |
| Logging | — (always captured) | captured in refs, not pushed to shared queue | same |
| `runAsync` | `tcAsync` | captures scenario without executing it (`readScheduledScenarios`) | spawns the scenario on a background thread through the same test interpreter; side effects land in the usual capture buffers / mailbox (no capture in `readScheduledScenarios`) |

## Typical Test Pattern

```haskell
spec :: Spec
spec = do
    it "sends a telegram message" $ do
        (mocks, _) <- runWithDefaultMocks app $ do
            runScenarioProgram myScenario

        requests <- readTgRequests mocks
        requests `shouldSatisfy` (not . null)

        logs <- readLog mocks
        logs `shouldSatisfy` elem (AppLogMsg "Scenario completed")
```

When no services are needed, use `NoServiceLib`:

```haskell
import LazyCircus.App.Service (NoServiceLib)

app :: DefaultApp NoServiceLib
```

## DB Integration Tests

This repository uses a real PostgreSQL database in DB tests.

Important project behavior:

- tests expect PostgreSQL at `127.0.0.1:5432`
- user `postgres`, password `my_password` is used for bootstrap
- app user `lazy_circus_app`, password `my_password`
- tests recreate `lazy_circus_test`
- migrations are plain SQL from `Common.migration`
- `aroundAll`-scoped fixtures (`withFreshTestDb`, `withBotTestApp` → `withDemoApp`) recreate the test database ONCE per spec and share one app (and its pools) across every `it` in that spec. Rows committed by one example stay visible to the next — per-example seeders must be idempotent or explicitly reset state (e.g. delete-then-seed), otherwise rows leak between examples inside the same spec

## Verifying Async Work

Because test `runAsync` only captures requests, assert on scheduled scenarios instead of side
effects.

```haskell
it "schedules background cleanup" $ do
    (mocks, _) <- runWithDefaultMocks app $ do
        runScenarioProgram myScenario

    asyncs <- readScheduledScenarios mocks
    length asyncs `shouldBe` 1
```

If you want to verify the deferred effect itself, explicitly run the captured scenario later with
the same test runtime and then inspect the corresponding capture buffer.

## Debugging: Where Did My Logs Go?

Scenario and scene logs are **never printed** during a test run — the test performer
captures them in mock refs (`appLog` / `appLogWithContext`) instead of draining the
production log queue. Nothing appears in the terminal, so when a test misbehaves, read
the captured entries back from the `Mocks` rather than building temporary dump helpers:

```haskell
(mocks, _) <- runWithDefaultMocks app $ runScenarioProgram myScenario
entries <- readLogWithContext mocks   -- or readLog mocks for bare payloads
mapM_ print entries                   -- or filter for the entry you are chasing
```

`readLogWithContext` returns `AppLogMsgWithContext` values (message + language tag +
call-site data + accumulated context); `readLog` returns the bare `AppLogMsg` payloads.
This works identically for logs emitted inside `tgTest` runs via the same `Mocks`.

## Verifying Log Context

Use `readLogWithContext` when the test cares about tags, call-site data, or enriched entries.

Typical checks include:

- scenario logs carrying `lang = "Scenario"`
- custom keys added via `withLogContext`
- sub-language logs preserving the outer context and adding their own language tag
- non-empty call-site metadata when emitted through standard logging helpers

## Verifying Telegram Capture

When a bot is configured in the app env:

- use `readTgRequests` for immediate `sendMessage` capture
- use `readScheduledTgRequests` for deferred Telegram queue capture
- use `getBotName` to verify dispatch selected the expected bot environment

When no bot is configured for a requested name, tests should assert `NoBotConfigured` rather than
expecting a silent no-op.

## Configurable TestPerformer

Module: `LazyCircus.Testing.Performer`

By default, every mockable sub-language (Telegram, AI, Mail-send) runs in `Mocked` mode — this is
the backward-compatible behavior that all existing specs rely on. For rare end-to-end tests that
need real external services (e.g. E2E against live OpenAI), each sub-language can be individually
switched to `Real` via `TestConfig`:

```haskell
data Mode = Mocked | Real

data TestConfig = TestConfig
    { tcTelegram :: Mode   -- Telegram send/receive
    , tcAI       :: Mode   -- AI ask / solveWithAgent
    , tcMailSend :: Mode   -- Mail send (SMTP)
    , tcAsync    :: Mode   -- runAsync (capture vs spawn)
    }

defaultTestConfig :: TestConfig   -- all Mocked (backward-compatible)
```

**Mode semantics:**

| Sub-language | `Mocked` (default) | `Real` |
|---|---|---|
| Telegram | mailbox capture + canned responses | `TG.*` API calls (real bot token required) |
| AI | transport intercept via `buildMockAiMethods` with FIFO canned responses | real `askAIContinuing` without override (real `cfgAiApiKey` required) |
| Mail send | capture in `readSentMails` | real SMTP via `Mail.sendMail` |
| Async (`runAsync`) | capture in `readScheduledScenarios` (no execution) | spawn on a background thread through the same test interpreter; side effects land in the usual capture buffers / mailbox |

DB and HTTP are **always real** — there is no mock for them. Async (`runAsync`) is the only
sub-language whose `Real` mode still captures side effects, because the spawned worker runs
through the same test interpreter.

**Configurable runners:**

```haskell
runWithConfig        :: DefaultApp sl -> TestConfig -> Mocks sl -> TestInterpreter sl a -> IO a
runWithDefaultConfig :: DefaultApp sl -> TestConfig -> TestInterpreter sl a -> IO (Mocks sl, a)
```

The existing `runWithMocks` / `runWithDefaultMocks` use `defaultTestConfig` (all-mocked) and remain
unchanged — no existing spec needs modification.

**Example: real-AI E2E test (requires real `cfgAiApiKey`):**

```haskell
import LazyCircus.Testing.Performer (defaultTestConfig, runWithDefaultConfig, TestConfig(..), Mode(..))

let realAiConfig = defaultTestConfig{tcAI = Real}
(mocks, result) <- runWithDefaultConfig app realAiConfig $
    runScenarioProgram (evalScript myAiScript)
-- result comes from the real OpenAI client; readAiRequests is empty (no transport intercept)
```

**Example: real-async test (worker genuinely runs, side effects captured):**

```haskell
import LazyCircus.Testing.Performer (defaultTestConfig, runWithDefaultConfig, TestConfig(..), Mode(..))

let realAsyncConfig = defaultTestConfig{tcAsync = Real}
(mocks, _) <- runWithDefaultConfig app realAsyncConfig $
    runScenarioProgram $ runAsync $ evalScript $ tgScript "demo-bot" $ sendMessage req
-- the spawned worker ran sendMessage through the same test interpreter, so it published an
-- OutgoingMessage to the outgoing mailbox (readOutgoingMailbox is NON-empty).
-- readScheduledScenarios is empty (Real mode does not capture the scenario).
```

**`runWithAiMocks` compatibility:** `runWithAiMocks` seeds canned AI responses into `Mocks.aiMock`
and delegates to `runWithMocks` (which uses `defaultTestConfig` → `tcAI = Mocked`). This remains
fully compatible — the AI mock seeding works because the `Mocked` branch reads `aiMock.mocks`.

**Important:** in `Real` mode, side effects are **not** captured in mock refs. `readAiRequests`,
`readSentMails`, `readTgRequests`, and `readOutgoingMailbox` will all be empty for their respective
Real-mode sub-languages. The exception is `tcAsync = Real`: the spawned worker runs through the
*same* test interpreter (same mocks, mailbox, and DB connection), so its side effects genuinely land
in the usual capture buffers and `readOutgoingMailbox` — only `readScheduledScenarios` stays empty.
`runWithConfigEngine` awaits all in-flight `tcAsync = Real` workers (bounded by a 5s timeout) before
draining logs and returning, so their side effects settle. An observe mode (real + simultaneous
capture) for the other sub-languages is deferred to a separate plan.

## Fake Telegram Updates

Module: `LazyCircus.Testing.Updates`

For synchronous, single-shot handler tests (where you call the handler directly
rather than through `runHeadlessBot`), this module builds fake `Update` values
without a live Telegram connection.

**Pure builders** (hardcode `update_id = 0`, chat id `1`):

| Builder | Produces |
|---|---|
| `mkTextUpdate txt` | a private-chat text message |
| `mkNonTextMessageUpdate` | a message with no `text` field (sticker/location branch) |

**Stateful `UpdateFactory`** (monotonically increasing `update_id`, for `tgTest`
or any loop that needs distinct ids):

| Builder | Produces |
|---|---|
| `newUpdateFactory` | a fresh factory whose first id is `1` |
| `nextUpdateId f` | the next id |
| `mkTextUpdateByUser f userId chatId txt` | text from a specific user/chat |
| `mkTextUpdateIn f chatId txt` | text in a specific chat (default user) |
| `mkFileUpdate f userId chatId fileId` | a document upload (metadata-free) |
| `mkDocumentUpdate f userId chatId doc` | a document upload carrying the full `Document` (client-declared name / MIME / size) |
| `mkDocument fileId` | a minimal `Document` value; attach metadata via record update |
| `mkCallbackQueryUpdate f userId chatId msgId cbData` | a `callback_query` on `msgId` |

Defaults: `defaultTestUserId = UserId 1001`, `defaultTestChatId = ChatId 1`.

### Example: synchronous handler test (mirrors `test/BotHandlerSpec.hs`)

```haskell
import BotApp (ChatState (..), Model (..))
import BotHandler (BotHandlerConfig (..), handleScenario)
import LazyCircus.Testing.Performer (readTgRequests, runScenarioProgram, runWithDefaultMocks)
import LazyCircus.Testing.Updates (mkTextUpdate)
import LazyCircus.Telegram.Types (WithImportance (..))
import Telegram.Bot.API (sendMessageText)

idleModel :: Model
idleModel = Model Idle emptyConversation

it "replies to /start with the welcome text" $ \app -> do
    (mocks, newModel) <- runWithDefaultMocks app $
        runScenarioProgram (handleScenario testConfig idleModel (mkTextUpdate "/start"))
    replies <- map (sendMessageText . importanceValue) <$> readTgRequests mocks
    replies `shouldSatisfy` (not . null)
    head replies `shouldSatisfy` ("🎪 Welcome to Lazy Circus Bot!" `Text.isPrefixOf`)
    modelChatState newModel `shouldBe` Idle
  where
    importanceValue (Regular a) = a
    importanceValue (Important a) = a
```

This pattern — drive `handleScenario` with a fake `Update` under the test
performer, then assert on `readTgRequests` captures and the returned `Model` —
is the lower-level complement to `tgTest`: faster and fully synchronous, but it
does not exercise the headless dispatch loop or the STM mailbox.

## Review Checklist

- Are async assertions aligned with the async mode (`readScheduledScenarios` / `mbScheduledScenarioCount` for `Mocked`; capture buffers / mailbox for `Real`)?
- Are logs read via `readLog` / `readLogWithContext` instead of expected in terminal output?
- Are canned downloads staged by `FileId` (third `createTgMock` argument or `addTgDownloads`) before Mocked download assertions?
