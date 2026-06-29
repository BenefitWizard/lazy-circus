# Lazy Circus Reference: Runtime And Testing

Read this when:

- debugging interpreter behavior
- working with `DefaultPerformer`, `evalScriptDefault`, or environment projection
- reasoning about async execution, extra context, bot lookup, or test semantics
- writing end-to-end Telegram bot tests with `tgTest` / `TelegramTestScript`
- building fake Telegram `Update`s with `LazyCircus.Testing.Updates`

## Runtimes And Environments

Lazy Circus relies on environment capabilities exposed via small lens-based typeclasses.

### Main Production Runtime

`LazyCircus.Performer.Default` defines:

```haskell
newtype DefaultPerformer env a = DefaultPerformer
    { runDefaultPerformer :: RIO env a }
```

`runDefaultScenario :: ScenarioProgram Script serviceLib a -> DefaultPerformer (DefaultApp serviceLib) a`

Note: `runDefaultScenario` is not currently exported. Production scenarios are run via the generic `run` function:
`runRIO app $ runDefaultPerformer $ run @Script @serviceLib myScenario`

`DefaultApp serviceLib` contains:

- primary PostgreSQL connection
- optional read-only PostgreSQL connection
- Telegram bot environments
- OpenAI client methods
- SMTP credentials
- shared logging queue and logging context
- extra context map
- scheduled async action queue
- JWT settings, process context, and a SQL log hook
- service library (or `NoServiceLib`)
- tool descriptions available to AI interpreters
- tool call executor for dispatching named tool calls with JSON arguments
- shared TLS connection manager for HTTP client requests

### Wrapper Environments

#### `AppWithConnection`

Module: `LazyCircus.DB.WithConnection`

Use this when one interpreter must run against a selected DB connection while preserving access
to the rest of the application environment.

The default performer uses it to choose between read-write and read-only DB connections.

#### `AppWithBotEnv`

Module: `LazyCircus.Telegram.Types`

Use this when a Telegram script needs one specific bot environment.

The default performer looks up the bot by name and projects into `AppWithBotEnv` before running
`runTelegram`.

### `changeEnv`

`changeEnv` projects one performer into another environment.

```haskell
changeEnv :: (outer -> inner) -> DefaultPerformer inner a -> DefaultPerformer outer a
```

This is not a lens update. It is a pure projection from outer environment to inner environment.

### Dispatch Paths

There are two important execution entry points:

1. `run` from `LazyCircus.Scenario` together with the generic `ScenarioPerformer Script serviceLib`
   instance in `LazyCircus.Performer`
2. `evalScriptDefault` from `LazyCircus.Performer.Default` — the production dispatch that
   pattern-matches on `Script` variants

The generic `ScenarioPerformer Script serviceLib` instance:

- dispatches `Script` by calling `runTelegram`, `runMail`, `runAI`, `runDB`, and `runHTTP`
- uses `async` directly for `runAsync`
- returns `mempty` from `getExtraContext'`

The default performer's `evalScriptDefault` is the production-specific dispatch. It:

- looks up the requested Telegram bot name and throws `NoBotConfigured` when absent
- projects into `AppWithBotEnv` before running `runTelegram`
- projects into `AppWithConnection` before running `runDB`
- uses the read-only PostgreSQL connection when configured and falls back to the primary one otherwise
- reads the real `extraContext` map from `DefaultApp`
- queues async work via `scheduleAsyncAction`

Tests use a third path, `runScenarioProgram`, which captures async requests instead of executing them.

## Testing

Module: `LazyCircus.Testing.Performer`

Use the testing performer when you want to run scenarios with mocked logging, Telegram,
mail, AI, and async scheduling. For end-to-end tests that drive the bot's own update
handler (routing, dialog state, inline keyboards), see
[End-to-End Telegram Bot Tests (`tgTest`)](#end-to-end-telegram-bot-tests-tgtest) below.

### Shared-Runner Architecture

The test runtime is not a separate reimplementation of scenario semantics. It keeps the same
shared-runner architecture as production:

- `ScenarioProgram` still runs through the normal scenario interpreter machinery
- top-level `Script` dispatch still chooses DB, Telegram, Mail, AI, and HTTP branches the same way
- environment projection still happens through wrappers like `AppWithConnection` and `AppWithBotEnv`

The main difference is the capability layer behind that runner:

- DB capability uses the real configured connection
- Telegram capability is replaced with capture-oriented mocks
- Mail capability reuses real mail construction but captures sends
- AI capability returns mock values (`Nothing` by default)
- HTTP capability executes real servant-client requests via the configured manager and base URL
- async capability captures scheduled scenarios instead of executing them
- logging capability captures structured entries instead of draining the production queue

This means tests exercise the same orchestration path as production while swapping effectful
capabilities at the edges.

### Key Types

| Type | Purpose |
|---|---|
| `Mocks serviceLib` | collected mock state (Tg requests, mails, logs, async tasks) |
| `TgMock` | Telegram mock with configurable response queue and an STM `outgoingMailbox` |
| `OutgoingMessage` | one captured outgoing Telegram side effect (kind, chat id, text, message id, reply markup) |
| `OutgoingKind` | tag on `OutgoingMessage`: `OutSendMessage` / `OutSendDocument` / `OutSetReaction` / `OutEditMessage` |
| `MailMock` | Mail mock for capturing sent mails |
| `EnvWithMocks serviceLib` | environment extended with mock state |
| `TestInterpreter serviceLib a` | the test-performer monad |
| `OnSendMessageRequest` | callback type for custom Telegram send handling |

### Main Helpers

| Function | Purpose |
|---|---|
| `makeMocks` | allocate a fresh mock state (including an empty `outgoingMailbox`) |
| `runWithMocks` | run with caller-supplied app and mocks |
| `runWithDefaultMocks` | allocate mocks and run |
| `runScenarioProgram` | execute a `ScenarioProgram Script` in `TestInterpreter` |
| `runScript` | execute one top-level `Script` |
| `runTestInterpreter` | unwrap a `TestInterpreter` action into the underlying `RIO (EnvWithMocks serviceLib)` |
| `readTgRequests` | read captured immediate `sendMessage` requests (legacy `SomeRef` log) |
| `readScheduledTgRequests` | read captured scheduled Telegram sends |
| `readOutgoingMailbox` | drain and return every `OutgoingMessage` still in the STM mailbox (destructive) |
| `readLog` | read captured log payloads |
| `readLogWithContext` | read contextualized log messages |
| `readSentMails` | read outgoing mails |
| `readScheduledScenarios` | read captured async scenario requests |

Also useful for custom harnesses:

- `runInsideWithMocks` and `runInsideWithDefaultMocks` run tests inside `RIO DefaultApp`
- `discardMocks` drops the collected capture state when only the result matters
- `createTgMock`, `createSimpleTgMock`, and `createSimpleMailMock` help build custom mock setups

### Mocked Sub-Language Runners

These run one sub-language in isolation with mock logging:

| Function | Scope |
|---|---|
| `runDBWithMockLogging` | DB script with captured logs |
| `runTelegramWithMockLogging` | Telegram script with captured logs |

### Mock Behavior Summary

| Effect | Test behavior |
|---|---|
| Telegram `sendMessage` | captures `WithImportance SendMessageRequest` in the `SomeRef` log (`readTgRequests`) AND publishes an `OutSendMessage` to the STM `outgoingMailbox` carrying a fresh incremental `MessageId`; returns the canned/default response stamped with that id |
| Telegram `sendDocument` | publishes an `OutSendDocument` to the `outgoingMailbox` (with a fresh incremental `MessageId`) and returns the mock `defaultResponse` stamped with that id; not added to the `readTgRequests` log |
| Telegram `setMessageReaction` | publishes an `OutSetReaction` to the `outgoingMailbox` carrying the target `MessageId` |
| Telegram `editMessageText` | publishes an `OutEditMessage` to the `outgoingMailbox`; still always returns `Nothing` |
| Telegram `setBotCommands` / `answerCallbackQuery` | no-op (return unit) |
| Telegram scheduled sends | captured in a separate `SomeRef` list (`readScheduledTgRequests`) |
| Telegram missing bot | throws `NoBotConfigured` exactly like production dispatch |
| Telegram `getBotName` | returns the supplied bot name |
| Telegram file loading | not implemented and throws |
| Mail `sendMail` | captures mail values |
| Mail `makeMail` | uses real mail construction from env creds |
| AI `ask` / `askContinuing` / `solveWithAgent` / `solveWithAgentContinuing` | always returns `Nothing` paired with an unchanged (empty) `Conversation` |
| HTTP `runClient` | real execution via servant-client against target base URL |
| DB | runs against a real DB connection |
| Logging | captured in refs, not pushed to shared queue |
| `runAsync` | captures scenario without executing it |

### Typical Test Pattern

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

### DB Integration Tests

This repository uses a real PostgreSQL database in DB tests.

Important project behavior:

- tests expect PostgreSQL at `127.0.0.1:5432`
- user `postgres`, password `my_password` is used for bootstrap
- app user `lazy_circus_app`, password `my_password`
- tests recreate `lazy_circus_test`
- migrations are plain SQL from `Common.migration`

### Verifying Async Work

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

### Verifying Log Context

Use `readLogWithContext` when the test cares about tags, call-site data, or enriched entries.

Typical checks include:

- scenario logs carrying `lang = "Scenario"`
- custom keys added via `withLogContext`
- sub-language logs preserving the outer context and adding their own language tag
- non-empty call-site metadata when emitted through standard logging helpers

### Verifying Telegram Capture

When a bot is configured in the app env:

- use `readTgRequests` for immediate `sendMessage` capture
- use `readScheduledTgRequests` for deferred Telegram queue capture
- use `getBotName` to verify dispatch selected the expected bot environment

When no bot is configured for a requested name, tests should assert `NoBotConfigured` rather than
expecting a silent no-op.

## End-to-End Telegram Bot Tests (`tgTest`)

Module: `LazyCircus.Testing.TgTest`

`tgTest` is a second Telegram-update /source/ alongside production polling
(`runPollingBot`) and webhooks. It drives the **same** bot handler seam
(an `Update -> IO ()` action) through the queue-fed
`Telegram.Bot.Extra.Headless.runHeadlessBot`, and intercepts every outgoing
Telegram side effect in the `LazyCircus.Testing.Performer` STM `outgoingMailbox`.
The DSL's `waitFor*` operations consume that mailbox deterministically via STM
`retry`, with a `registerDelay` timeout as the only non-deterministic safety net.

The design is "one more source for the same handler": production runs
`runPollingBot`, tests run `runHeadlessBot`. Because dispatch is fire-and-forget,
every `waitFor*` blocks through STM (never by reading once and hoping) so it is
woken the moment the performer publishes a reply.

### Why this is different from `runScenarioProgram`

`runScenarioProgram` (above) tests a `ScenarioProgram` you constructed directly.
`tgTest` tests your **bot's update handler** end-to-end: you write a `TelegramTestScript`
that sends fake user input and waits for the bot's replies, while the handler runs
its ordinary script under the test performer — Telegram/AI/mail mocked, DB real,
replies landing in the shared mailbox. This catches routing, dialog-state, and
FSM bugs that a hand-built scenario cannot.

### The runner contract

```haskell
tgTest ::
    TgTestConfig ->
    (Mocks serviceLib -> IO (Update -> IO ())) ->
    TelegramTestScript a ->
    IO (Mailboxes, Either TgTestError a)
```

`tgTest` owns the observable state: it allocates a fresh `Mocks` (and thus a
fresh mailbox), builds a `TgTestRuntime`, and hands the `Mocks` to `buildAction`
so your bot driver can run under the test performer against the **same** mocks.
It then spawns `runHeadlessBot` in a background thread, feeds the DSL's `send*`
updates into the bot, observes replies through the mailbox, and returns the final
`Mailboxes` snapshot together with either the DSL result or a `TgTestError`.

`buildAction` receives the mocks and returns the bot's `Update -> IO ()` action —
normally your production update-driver with `runWithMocks` substituted for the
production performer. That is how the test runs the bot's ordinary script with
everything mocked.

```haskell
defaultTgTestConfig :: TgTestConfig   -- 2-second waitFor* timeout
```

### The `buildAction` seam

The only application-specific obligation is `buildAction`. It wires the bot's
ordinary update-driver under the test performer. A typical `buildAction` runs the
very same driver production uses, only with `runWithMocks` substituted for the
production performer:

```haskell
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Testing.Performer (Mocks, runScenarioProgram, runWithMocks)
import LazyCircus.Testing.TgTest (tgTest, defaultTgTestConfig)
import Telegram.Bot.API (Update)

-- | Your bot's update-driver, identical to production except the performer is
-- the test performer. 'runYourDriver' is whatever turns an @Update@ into an
-- @IO ()@ by running the handler's ScenarioProgram.
buildAction :: DefaultApp serviceLib -> Mocks serviceLib -> IO (Update -> IO ())
buildAction app mocks =
    pure $ runYourDriver (runWithMocks app mocks . runScenarioProgram) cfg

runTgTest :: DefaultApp serviceLib -> TelegramTestScript a -> IO (Mailboxes, Either TgTestError a)
runTgTest app = tgTest defaultTgTestConfig (buildAction app)
```

See `test/TestHelpers/Bot.hs` for the canonical wiring against the demo bot's
`BotHandler.runUpdate`.

### The DSL

`TelegramTestScript` is a `ReaderT TgTestRuntime (ExceptT TgTestError IO)`. A
failing `guard` or `waitFor*` short-circuits to `Left`.

**Sending fake user input** (each returns the update's `UpdateId`):

| Operation | Input produced |
|---|---|
| `sendMessage txt` | text from `defaultTestUserId` in `defaultTestChatId` |
| `sendMessageIn chatId txt` | text in a specific chat |
| `sendMessageByUser userId chatId txt` | text from a specific user/chat |
| `sendFile fileId` / `sendFileByUser ...` | a document upload |
| `sendKeypress msgId cbData` / `sendKeypressByUser ...` | a `callback_query` on an inline keyboard |

**Waiting for bot replies** (block via STM `retry`, fail with `TgTestTimeout` on timeout):

| Operation | Returns |
|---|---|
| `waitForReply` / `waitForReplyIn chatId` | the reply `Text` |
| `waitForReplies n` | `n` reply texts, earliest-first |
| `waitForReplyWithKeyboard` / `...In chatId` | `(Text, MessageId)` for a reply carrying an inline keyboard |
| `waitForReaction msgId` | `()` when the bot reacts on `msgId` |
| `waitForFile` | `FileId` for a document reply (stable placeholder, see Haddock) |
| `waitForMatching predicate desc` | the matched `OutgoingMessage` (the low-level primitive) |

Non-matching messages are moved to a deferred buffer and re-offered to the next
wait, so a multi-chat script can wait selectively without losing earlier traffic.

**Assertions and control:**

| Operation | Effect |
|---|---|
| `guard bool` / `guardWith reason bool` | abort with `TgTestGuardFailed` unless the predicate holds |
| `withTimeout us script` | run a sub-program with a different `waitFor*` timeout |

### Example: green-path dialog (mirrors `test/TgTestSpec.hs`)

```haskell
{-# LANGUAGE OverloadedStrings #-}

import RIO
import RIO.Text qualified as Text
import Test.Hspec

import LazyCircus.Testing.TgTest
    ( guardWith, sendMessage, waitForReply )

-- A self-contained DSL script: send /newact, walk both prompt turns, read the
-- progress + formatted-act replies, and assert each step.
newactPilot :: TelegramTestScript ()
newactPilot = do
    _ <- sendMessage "/newact"
    r1 <- waitForReply
    guardWith "expected the act-name prompt" (r1 == "🎭 Enter act name:")

    _ <- sendMessage "Fire Juggling"
    r2 <- waitForReply
    guardWith "expected the act-description prompt" (r2 == "📝 Enter act description:")

    _ <- sendMessage "Breathes fire"
    -- The description turn emits a progress reply followed by the formatted act.
    progress <- waitForReply
    guardWith "expected the creating-act progress reply" (progress == "⏳ Creating act...")
    r3 <- waitForReply
    guardWith "expected the formatted act to contain its name"
              ("Fire Juggling" `Text.isInfixOf` r3)

spec :: Spec
spec = aroundAll withBotTestApp $
    it "completes the full /newact dialog end-to-end" $ \app -> do
        (_mailboxes, result) <- runTgTest app newactPilot
        case result of
            Left e   -> expectationFailure ("dialog aborted: " ++ show e)
            Right _  -> pure ()
```

### Example: inline-keyboard button press + reaction

```haskell
keyboardPilot :: TelegramTestScript ()
keyboardPilot = do
    _ <- sendMessage "/menu"
    (caption, botMsgId) <- waitForReplyWithKeyboard   -- bot sent an inline keyboard
    sendKeypress botMsgId "confirm"                   -- press the "confirm" button
    waitForReaction botMsgId                          -- bot reacted on its own message
```

### Example: timeout / negative path (mirrors `test/TgTestRunnerSpec.hs`)

A `waitFor*` with no forthcoming reply aborts with `TgTestTimeout`. Wrap only
the wait that should time out in a short `withTimeout` so the example stays fast:

```haskell
import LazyCircus.Testing.TgTest
    ( TgTestError (..), sendMessage, waitForReply, withTimeout )

timeoutPilot :: TelegramTestScript ()
timeoutPilot = do
    _ <- sendMessage "/start"
    _ <- waitForReply            -- consumed under the default generous timeout
    withTimeout 200000 waitForReply   -- 0.2s; no second reply arrives -> TgTestTimeout

-- assert
case result of
    Left (TgTestTimeout _) -> pure ()
    other                  -> expectationFailure ("expected TgTestTimeout, got: " ++ show other)
```

A deliberately-wrong `guard` analogously aborts with `TgTestGuardFailed`.

### Inspecting the mailbox after the run

The returned `Mailboxes` is a final observable snapshot:

```haskell
data Mailboxes = Mailboxes
    { mbOutgoing              :: [OutgoingMessage]   -- deferred non-matches + leftover mailbox
    , mbScheduledScenarioCount :: Int                -- runAsync programs captured (not executed)
    }
```

For assertions over side-effect *kinds* and *order* (rather than over the dialog
flow), drain the mailbox with `readOutgoingMailbox` and inspect `OutgoingMessage`
fields. This mirrors `test/TgMockMailboxSpec.hs`:

```haskell
import LazyCircus.Testing.Performer
    ( OutgoingKind (..), readOutgoingMailbox, runScenarioProgram, runWithDefaultMocks )
import Telegram.Bot.API.Types (MessageId (..))

it "publishes two sends with distinct incremental message ids" $ \app -> do
    (mocks, _) <- runWithDefaultMocks app $
        runScenarioProgram $ do
            sendTo (ChatId 1) "first"
            sendTo (ChatId 1) "second"

    msgs <- readOutgoingMailbox mocks
    map omKind msgs `shouldBe` [OutSendMessage, OutSendMessage]
    map omText  msgs `shouldBe` [Just "first", Just "second"]
    [ mid | Just mid <- map omMessageId msgs ] `shouldBe` [MessageId 0, MessageId 1]
```

`OutgoingKind` discriminates the four captured operations: `OutSendMessage`,
`OutSendDocument`, `OutSetReaction`, `OutEditMessage`. `omMessageId` is the
assigned incremental id for `sendMessage`/`sendDocument`, or the target id for
`setMessageReaction`/`editMessageText`.

### Teardown and quiescence

`runHeadlessBot` dispatches each update fire-and-forget via `asyncLink`; those
per-update threads are NOT cancelled when the drain loop is cancelled (a known
library limitation). To keep the `Mailboxes` snapshot deterministic and to avoid
an in-flight action thread touching the app's DB connection after teardown,
`tgTest` waits for the update queue to drain AND for the in-flight action count
to reach zero (bounded by a 5s `quiescenceTimeout`) before it cancels the drain
loop and snapshots. A short grace covers the microsecond dequeue→spawn window.

Consequence for tests: a `tgTest` run cannot hang on a stuck action, and the
snapshot reflects all side effects once in-flight work has settled.

### Common mistakes with `tgTest`

- **Polling instead of STM.** Never write a custom `waitFor` that reads the
  mailbox once and retries on a timer — use the built-in `waitFor*` (or
  `waitForMatching`), which block on STM `retry` and wake deterministically.
- **Forgetting to share the mocks.** `buildAction` MUST wire the test performer
  against the *same* `Mocks` the runner handed it, or replies never reach the
  mailbox the DSL observes.
- **Asserting on side effects from `runAsync`.** Test `runAsync` only captures
  scheduled scenarios — assert via `mbScheduledScenarioCount` or
  `readScheduledScenarios`, never via observed Telegram traffic.
- **Expecting `waitForFile` to return the bot's real `FileId`.** The MVP mailbox
  capture does not retain the full `SendDocumentRequest`; the returned id is a
  stable placeholder suitable only for ordering assertions.

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
| `mkFileUpdate f userId chatId fileId` | a document upload |
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
