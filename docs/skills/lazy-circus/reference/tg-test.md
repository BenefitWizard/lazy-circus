# Lazy Circus Reference: End-to-End Telegram Bot Tests (`tgTest`)

Read this when:

- writing end-to-end dialog tests with `tgTest` / `TelegramTestScript` (module `LazyCircus.Testing.TgTest`)
- using the DSL: `waitFor*`, `sendFileByUser`, `sendDocumentAs`, `sendKeypress`, `guard`
- inspecting the outgoing mailbox after a run

## Contents

- Design
- Why this is different from `runScenarioProgram`
- The Runner Contract
- The `buildAction` Seam
- The DSL
- Example: green-path dialog
- Example: inline-keyboard button press + reaction
- Example: timeout / negative path
- Inspecting The Mailbox After The Run
- Teardown And Quiescence
- Common Mistakes

## Design

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

Every Telegram `sendMessage` / `sendDocument` / `setMessageReaction` /
`editMessageText` / `deleteMessage` publishes an `OutgoingMessage` (tagged with
`OutgoingKind`) to the STM mailbox; `sendMessage`/`sendDocument` responses are
stamped with a fresh incremental `MessageId` (see the mock behavior table in
[testing.md](testing.md)).

## Why this is different from `runScenarioProgram`

`runScenarioProgram` (see [testing.md](testing.md)) tests a `ScenarioProgram` you
constructed directly. `tgTest` tests your **bot's update handler** end-to-end:
you write a `TelegramTestScript` that sends fake user input and waits for the
bot's replies, while the handler runs its ordinary script under the test
performer — Telegram/AI/mail mocked, DB real, replies landing in the shared
mailbox. This catches routing, dialog-state, and FSM bugs that a hand-built
scenario cannot.

## The Runner Contract

```haskell
tgTest ::
    TgTestConfig ->
    (TestConfig -> Mocks serviceLib -> IO (Update -> IO ())) ->
    TelegramTestScript a ->
    IO (Mailboxes, Either TgTestError a)
```

`tgTest` owns the observable state: it allocates a fresh `Mocks` (and thus a
fresh mailbox), builds a `TgTestRuntime`, and hands the `TestConfig` (from
`ttgPerformerConfig`) plus the `Mocks` to `buildAction` so your bot driver can
run under the test performer against the **same** mocks. It then spawns
`runHeadlessBot` in a background thread, feeds the DSL's `send*` updates into
the bot, observes replies through the mailbox, and returns the final
`Mailboxes` snapshot together with either the DSL result or a `TgTestError`.

`buildAction` receives the performer `TestConfig` and the mocks, and returns
the bot's `Update -> IO ()` action — normally your production update-driver
with `runWithConfig` (honoring the supplied config) substituted for the
production performer. That is how the test runs the bot's ordinary script with
the configured mock/real modes.

```haskell
data TgTestConfig = TgTestConfig
    { ttgTimeout         :: Int         -- microseconds for waitFor* timeout
    , ttgPerformerConfig :: TestConfig  -- per-sub-language mock/real mode
    }

defaultTgTestConfig :: TgTestConfig   -- 2-second timeout, all-mocked performer config
```

**Runtime guard:** `tgTest` throws `TgTestConfigError` **before** starting the
headless bot if `tcTelegram` (from `ttgPerformerConfig`) is `Real`. This is
because `tgTest` observes bot replies through the STM outgoing mailbox, which a
real Telegram API never populates — a real-Telegram `tgTest` would hang forever
on the first `waitFor*`. AI and Mail may still be `Real` inside `tgTest` (they
do not interfere with the mailbox mechanism).

## The `buildAction` Seam

The only application-specific obligation is `buildAction`. It wires the bot's
ordinary update-driver under the test performer. A typical `buildAction` runs the
very same driver production uses, only with `runWithConfig` (honoring the
supplied `TestConfig`) substituted for the production performer:

```haskell
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Testing.Performer (Mocks, TestConfig, runScenarioProgram, runWithConfig)
import LazyCircus.Testing.TgTest (tgTest, defaultTgTestConfig)
import Telegram.Bot.API (Update)

-- | Your bot's update-driver, identical to production except the performer is
-- the test performer. 'runYourDriver' is whatever turns an @Update@ into an
-- @IO ()@ by running the handler's ScenarioProgram.
buildAction :: DefaultApp serviceLib -> TestConfig -> Mocks serviceLib -> IO (Update -> IO ())
buildAction app cfg mocks =
    pure $ runYourDriver (runWithConfig app cfg mocks . runScenarioProgram) handlerCfg

runTgTest :: DefaultApp serviceLib -> TelegramTestScript a -> IO (Mailboxes, Either TgTestError a)
runTgTest app = tgTest defaultTgTestConfig (buildAction app)
```

See `test/TestHelpers/Bot.hs` for the canonical wiring against the demo bot's
`BotHandler.runUpdate`.

## The DSL

`TelegramTestScript` is a `ReaderT TgTestRuntime (ExceptT TgTestError IO)`. A
failing `guard` or `waitFor*` short-circuits to `Left`.

**Sending fake user input.** The message-sending ops (`sendMessage`, `sendMessageIn`,
`sendMessageByUser`, `sendFile`, `sendFileByUser`) return `(UpdateId, MessageId)` — the
`MessageId` is the sent user message's id, suitable for passing to `waitForReaction` or
`sendKeypress`. The `sendKeypress*` ops return just `UpdateId`.

| Operation | Input produced |
|---|---|
| `sendMessage txt` | text from `defaultTestUserId` in `defaultTestChatId` |
| `sendMessageIn chatId txt` | text in a specific chat |
| `sendMessageByUser userId chatId txt` | text from a specific user/chat |
| `sendFile fileId` / `sendFileByUser ...` | a document upload (metadata-free) |
| `sendDocumentByUser userId chatId doc` / `sendDocumentAs fileId name mime size` | a document upload carrying the client-declared `file_name` / `mime_type` / `file_size` (for metadata pre-check tests) |
| `sendKeypress msgId cbData` / `sendKeypressByUser ...` | a `callback_query` on an inline keyboard |

Note: the client-declared document metadata (`file_name` / `mime_type` / `file_size` from
the update) is the sender's **claim** — spoofable, and by design it may disagree with the
staged canned download (that disagreement is how size-spoofing pre-checks are tested).
Metadata-free uploads (`sendFile` / `sendFileByUser`) are the default; use
`sendDocumentAs` (DSL) or `mkDocumentUpdate` / `mkDocument` (factory, see
[testing.md](testing.md#fake-telegram-updates)) to inject declared metadata.

**Waiting for bot replies** (block via STM `retry`, fail with `TgTestTimeout` on timeout):

| Operation | Returns |
|---|---|
| `waitForReply` / `waitForReplyIn chatId` | the reply `Text` |
| `waitForReplies n` | `n` reply texts, earliest-first |
| `waitForReplyWithKeyboard` / `...In chatId` | `(Text, MessageId)` for a reply carrying an inline keyboard |
| `waitForReaction msgId` | `()` when the bot reacts on `msgId` |
| `waitForDeletion msgId` | `()` when the bot deletes `msgId` (mirror of `waitForReaction`) |
| `waitForFile` | `FileId` for a document reply (stable placeholder, see below) |
| `waitForMatching predicate desc` | the matched `OutgoingMessage` (the low-level primitive) |

Non-matching messages are moved to a deferred buffer and re-offered to the next
wait, so a multi-chat script can wait selectively without losing earlier traffic.

**Assertions and control:**

| Operation | Effect |
|---|---|
| `guard bool` / `guardWith reason bool` | abort with `TgTestGuardFailed` unless the predicate holds |
| `withTimeout us script` | run a sub-program with a different `waitFor*` timeout |

DSL signatures (module `LazyCircus.Testing.TgTest`; types from `Telegram.Bot.API`):

```haskell
-- senders (fake user input)
sendMessage        :: Text -> TelegramTestScript (UpdateId, MessageId)
sendMessageIn      :: ChatId -> Text -> TelegramTestScript (UpdateId, MessageId)
sendMessageByUser  :: UserId -> ChatId -> Text -> TelegramTestScript (UpdateId, MessageId)
sendFile           :: FileId -> TelegramTestScript (UpdateId, MessageId)
sendFileByUser     :: UserId -> ChatId -> FileId -> TelegramTestScript (UpdateId, MessageId)
sendDocumentByUser :: UserId -> ChatId -> Document -> TelegramTestScript (UpdateId, MessageId)
sendDocumentAs     :: FileId -> Maybe Text -> Maybe Text -> Maybe Integer
                   -> TelegramTestScript (UpdateId, MessageId)          -- fileId, name, mime, size
sendKeypress       :: MessageId -> Text -> TelegramTestScript UpdateId
sendKeypressByUser :: UserId -> ChatId -> MessageId -> Text -> TelegramTestScript UpdateId

-- waiting for bot replies
waitForReply             :: TelegramTestScript Text
waitForReplyIn           :: ChatId -> TelegramTestScript Text
waitForReplies           :: Int -> TelegramTestScript [Text]
waitForReplyWithKeyboard :: TelegramTestScript (Text, MessageId)   -- also ...In chatId variant
waitForReaction          :: MessageId -> TelegramTestScript ()
waitForDeletion          :: MessageId -> TelegramTestScript ()
waitForFile              :: TelegramTestScript FileId              -- placeholder id, see Common Mistakes
waitForMatching          :: (OutgoingMessage -> Bool) -> Text -> TelegramTestScript OutgoingMessage

-- assertions / control
guard            :: Bool -> TelegramTestScript ()
guardWith        :: Text -> Bool -> TelegramTestScript ()
withTimeout      :: Int -> TelegramTestScript a -> TelegramTestScript a
```

## Example: green-path dialog (mirrors `test/TgTestSpec.hs`)

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

## Example: inline-keyboard button press + reaction

```haskell
keyboardPilot :: TelegramTestScript ()
keyboardPilot = do
    _ <- sendMessage "/menu"
    (caption, botMsgId) <- waitForReplyWithKeyboard   -- bot sent an inline keyboard
    sendKeypress botMsgId "confirm"                   -- press the "confirm" button
    waitForReaction botMsgId                          -- bot reacted on its own message
```

## Example: timeout / negative path (mirrors `test/TgTestRunnerSpec.hs`)

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

## Inspecting The Mailbox After The Run

The returned `Mailboxes` is a final observable snapshot:

```haskell
data Mailboxes = Mailboxes
    { mbOutgoing              :: [OutgoingMessage]   -- deferred non-matches + leftover mailbox
    , mbScheduledScenarioCount :: Int                -- runAsync programs captured (not executed); reflects only 'tcAsync = Mocked' (Real mode spawns workers whose side effects land in 'mbOutgoing')
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

`OutgoingKind` discriminates the five captured operations: `OutSendMessage`,
`OutSendDocument`, `OutSetReaction`, `OutEditMessage`, `OutDeleteMessage`.
`omMessageId` is the assigned incremental id for `sendMessage`/`sendDocument`,
or the target id for `setMessageReaction`/`editMessageText`/`deleteMessage`.

## Teardown And Quiescence

`runHeadlessBot` dispatches each update fire-and-forget via `asyncLink`; those
per-update threads are NOT cancelled when the drain loop is cancelled (a known
library limitation). To keep the `Mailboxes` snapshot deterministic and to avoid
an in-flight action thread touching the app's DB connection after teardown,
`tgTest` waits for the update queue to drain AND for the in-flight action count
to reach zero (bounded by a 5s `quiescenceTimeout`) before it cancels the drain
loop and snapshots. A short grace covers the microsecond dequeue→spawn window.

Consequence for tests: a `tgTest` run cannot hang on a stuck action, and the
snapshot reflects all side effects once in-flight work has settled.

## Common Mistakes

- **Polling instead of STM.** Never write a custom `waitFor` that reads the
  mailbox once and retries on a timer — use the built-in `waitFor*` (or
  `waitForMatching`), which block on STM `retry` and wake deterministically.
- **Forgetting to share the mocks.** `buildAction` MUST wire the test performer
  against the *same* `Mocks` the runner handed it, or replies never reach the
  mailbox the DSL observes.
- **Asserting on side effects from `runAsync` in Mocked mode.** Test `runAsync` with
  `tcAsync = Mocked` (the default) only captures scheduled scenarios — assert via
  `mbScheduledScenarioCount` or `readScheduledScenarios`, never via observed Telegram traffic.
  With `tcAsync = Real` the worker is spawned and its side effects DO appear in the mailbox /
  capture buffers, so that assertion no longer holds.
- **Expecting `waitForFile` to return the bot's real `FileId`.** The MVP mailbox
  capture does not retain the full `SendDocumentRequest`; the returned id is a
  stable placeholder suitable only for ordering assertions.
- **Forgetting to stage canned downloads.** A Mocked `getFile` /
  `downloadFileById` / `downloadCheckedFile` throws for a `FileId` that has no
  staged bytes — inject them via `addTgDownloads` or the third `createTgMock`
  argument first (see `test/TgFileOpsSpec.hs` for the full upload → download →
  reply → `waitForDeletion` pattern).
