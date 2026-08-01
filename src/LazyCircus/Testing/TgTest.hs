{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The @tgTest@ end-to-end runner and its 'TelegramTestScript' DSL — a reusable
public testing API for Lazy Circus Telegram bots.

@tgTest@ is a second Telegram-update /source/ alongside production polling
('Telegram.Bot.Extra.Polling.runPollingBot'): it drives the /same/ bot handler
seam (an @Update -> IO ()@ action) through the queue-fed
'Telegram.Bot.Extra.Headless.runHeadlessBot', and intercepts every outgoing
Telegram side effect in the 'LazyCircus.Testing.Performer' STM mailbox. The
DSL's @waitFor*@ operations consume that mailbox deterministically via STM, with
a 'registerDelay' timeout as the only non-deterministic safety net.

The runner is /generic/: it knows nothing about your handler. You supply a
@buildAction :: TestConfig -> Mocks serviceLib -> IO (Update -> IO ())@ that
wires your bot's ordinary update-driver under the test performer (so
Telegram\/AI\/mail are mocked and replies land in the shared mailbox). The
runner feeds fake updates the DSL produces and observes the replies. A typical
@buildAction@ runs the very same driver production uses, only with
'LazyCircus.Testing.Performer.runWithConfig' (or the all-mocked
'LazyCircus.Testing.Performer.runWithMocks') substituted for the production
performer — the bot executes its ordinary script, everything is mocked as
expected.

'tgTest' refuses to start if the performer config requests real Telegram
('LazyCircus.Testing.Performer.tcTelegram' = 'LazyCircus.Testing.Performer.Real')
and throws 'TgTestConfigError' before spawning the headless bot, because it
observes replies only through the STM outgoing mailbox that a real Telegram API
never populates. AI and Mail MAY still be 'LazyCircus.Testing.Performer.Real'
inside a 'tgTest' run.

The design is "one more source for the same handler": production runs
'runPollingBot', webhook runs @serverWithAction@, tests run 'runHeadlessBot'.
Because dispatch is fire-and-forget (@asyncLink@), every @waitFor*@ MUST block
through STM @retry@ (never by reading once and hoping) so it is woken the moment
the performer publishes a reply — see 'waitForMatching'.
-}
module LazyCircus.Testing.TgTest (
    -- * Configuration
    TgTestConfig (..),
    defaultTgTestConfig,
    TgTestConfigError (..),
    -- * The runner
    tgTest,
    makeTestRuntime,
    Mailboxes (..),
    TgTestError (..),
    tgeDescription,
    -- * The DSL monad
    TelegramTestScript,
    -- ** Sending fake user input
    sendMessage,
    sendMessageByUser,
    sendMessageIn,
    sendFile,
    sendFileByUser,
    sendKeypress,
    sendKeypressByUser,
    -- ** Waiting for bot replies
    waitForReplies,
    waitForReply,
    waitForReplyIn,
    waitForReplyWithKeyboard,
    waitForReplyWithKeyboardIn,
    waitForReaction,
    waitForFile,
    -- ** Assertions and control
    guard,
    guardWith,
    withTimeout,
    -- * Lower-level building blocks
    waitForMatching,
    ) where

import Control.Concurrent.STM (retry)
import Control.Exception (SomeException)
import Control.Monad (replicateM)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Control.Monad.Trans.Reader qualified as Reader
import RIO hiding (guard)
import RIO.Text qualified as Text

import Telegram.Bot.API (ChatId (..), Update, UserId (..), messageMessageId, updateMessage)
import Telegram.Bot.API.GettingUpdates (UpdateId, updateUpdateId)
import Telegram.Bot.API.Types (FileId (..), MessageId (..))
import Telegram.Bot.Extra.Headless (feedUpdates, runHeadlessBot)

import LazyCircus.Testing.Performer
    ( Mocks
    , Mode (..)
    , OutgoingKind (..)
    , OutgoingMessage (..)
    , TestConfig (..)
    , defaultTestConfig
    , makeMocks
    , outgoingMailbox
    , readOutgoingMailbox
    , readScheduledScenarios
    , tgMock
    )
import LazyCircus.Testing.Updates
    ( UpdateFactory
    , defaultTestChatId
    , defaultTestUserId
    , mkCallbackQueryUpdate
    , mkFileUpdate
    , mkTextUpdateByUser
    , newUpdateFactory
    )

-- | Run-level configuration for 'tgTest'.
data TgTestConfig = TgTestConfig
    { ttgTimeout :: !Int
      -- ^ microseconds a @waitFor*@ waits before failing with 'TgTestTimeout'
    , ttgPerformerConfig :: !TestConfig
      -- ^ per-sub-language performer config (Telegram MUST be 'Mocked' for
      -- 'tgTest'; see 'TgTestConfigError')
    }

-- | Default config: a 2-second @waitFor*@ timeout (generous to absorb CI jitter),
-- with the default all-mocked performer config.
defaultTgTestConfig :: TgTestConfig
defaultTgTestConfig =
    TgTestConfig
        { ttgTimeout = 2_000_000
        , ttgPerformerConfig = defaultTestConfig
        }

-- | Raised by 'tgTest' when the performer config requests real Telegram.
-- 'tgTest' observes bot replies through the STM outgoing mailbox, which a real
-- Telegram API never populates — so a real-Telegram 'tgTest' would hang forever
-- on the first @waitFor*@.
newtype TgTestConfigError = TgTestConfigError Text
    deriving stock (Show)

-- | Enables throwing and catching 'TgTestConfigError' as a typed exception.
instance Exception TgTestConfigError

-- | Why a 'tgTest' run terminated without producing a result.
data TgTestError
    = TgTestGuardFailed !Text
    -- ^ a 'guard' assertion did not hold (carries a human-readable reason)
    | TgTestTimeout !Text
    -- ^ a @waitFor*@ timed out before a matching reply arrived (carries what was awaited)
    | TgTestActionError !SomeException
    -- ^ the bot's @updateAction@ threw an exception (routed via @onActionError@)
    deriving stock (Show)

-- | Render a 'TgTestError' as a single-line reason, matching the brief's
-- @(Mailboxes, Either Text a)@ shape where @Left@ carries a human reason.
tgeDescription :: TgTestError -> Text
tgeDescription (TgTestGuardFailed reason) = "guard failed: " <> reason
tgeDescription (TgTestTimeout awaited) = "timed out waiting for " <> awaited
tgeDescription (TgTestActionError e) = "bot action threw: " <> tshow e

-- | Final observable snapshot returned by 'tgTest'.
data Mailboxes = Mailboxes
    { mbOutgoing :: ![OutgoingMessage]
    -- ^ all outgoing Telegram side effects still observable after the DSL
    -- finished (deferred non-matches plus anything left in the mailbox)
    , mbScheduledScenarioCount :: !Int
    -- ^ number of @runAsync@ control programs captured (not executed) during the
    -- run. Reflects only 'tcAsync = Mocked' scheduling; with 'tcAsync = Real'
    -- async workers are spawned (their side effects land in 'mbOutgoing') and
    -- this count stays 0
    }

-- | Mutable per-run state shared between the DSL and the headless dispatch loop.
data TgTestRuntime = TgTestRuntime
    { ttrQueue :: !(TBQueue Update)
    -- ^ queue fed into 'runHeadlessBot'
    , ttrMailbox :: !(TBQueue OutgoingMessage)
    -- ^ the performer's outgoing mailbox (shared with 'Mocks.tgMock')
    , ttrDeferred :: !(TVar [OutgoingMessage])
    -- ^ messages dequeued by a @waitFor*@ but not matched by its predicate,
    -- preserved in FIFO order for a subsequent wait
    , ttrError :: !(TVar (Maybe SomeException))
    -- ^ error channel written by @onActionError@ when the bot action throws
    , ttrInflight :: !(TVar Int)
    -- ^ count of bot-action threads currently running (spawned fire-and-forget
    -- by @asyncLink@); awaited at 'tgTest' teardown so the snapshot is taken
    -- only once in-flight work has settled and no action thread can touch a
    -- closed DB connection after the surrounding app teardown
    , ttrConfig :: !TgTestConfig
    , ttrFactory :: !UpdateFactory
    }

-- | Allocate a fresh 'TgTestRuntime' wired to the supplied mocks (so the DSL
-- reads the same mailbox the performer publishes to) and config.
-- PRE-CONTRACT: @mocks@ must be the same 'Mocks' the supplied 'tgTest'
-- @buildAction@ will wire into the test performer.
-- POST-CONTRACT: The returned runtime is fresh (empty queue/mailbox/deferred,
-- zero inflight) and safe to use for exactly one 'tgTest' run.
makeTestRuntime :: TgTestConfig -> Mocks serviceLib -> IO TgTestRuntime
makeTestRuntime cfg mocks = do
    queue <- newTBQueueIO 64
    errVar <- newTVarIO Nothing
    deferred <- newTVarIO []
    inflight <- newTVarIO (0 :: Int)
    factory <- newUpdateFactory
    pure
        TgTestRuntime
            { ttrQueue = queue
            , ttrMailbox = outgoingMailbox (tgMock mocks)
            , ttrDeferred = deferred
            , ttrError = errVar
            , ttrInflight = inflight
            , ttrConfig = cfg
            , ttrFactory = factory
            }

-- | The @tgTest@ DSL monad: a reader over 'TgTestRuntime' layered with an
-- 'ExceptT' short-circuit so a failing 'guard'/'waitFor*' aborts to 'Left'.
newtype TelegramTestScript a = TelegramTestScript (Reader.ReaderT TgTestRuntime (ExceptT TgTestError IO) a)
    deriving newtype (Functor, Applicative, Monad, MonadIO)

-- | Run a DSL program against a runtime, yielding the short-circuit result.
runTelegramTestScript :: TgTestRuntime -> TelegramTestScript a -> IO (Either TgTestError a)
runTelegramTestScript rt (TelegramTestScript m) = runExceptT (Reader.runReaderT m rt)

-- | Read the current runtime.
ttsAsk :: TelegramTestScript TgTestRuntime
ttsAsk = TelegramTestScript Reader.ask

-- | Run a DSL program with a locally-modified runtime.
ttsLocal :: (TgTestRuntime -> TgTestRuntime) -> TelegramTestScript a -> TelegramTestScript a
ttsLocal f (TelegramTestScript m) = TelegramTestScript (Reader.local f m)

-- | Abort the DSL with a 'TgTestError'.
ttsThrow :: TgTestError -> TelegramTestScript a
ttsThrow e = TelegramTestScript $ lift (throwE e)

{- | Run a 'TelegramTestScript' end-to-end.

The runner owns the observable state: it allocates a fresh 'Mocks' (and thus a
fresh mailbox), builds a 'TgTestRuntime' via 'makeTestRuntime', and hands both
the per-sub-language 'TestConfig' and the @Mocks@ to @buildAction@ so your bot
driver can run under the test performer against the /same/ mocks. It then spawns
'runHeadlessBot' in a background thread, feeds the DSL's @send*@ updates into
the bot, and observes replies through the mailbox. Returns the final 'Mailboxes'
and either the DSL result or a 'TgTestError'.

@buildAction@ receives the 'TestConfig' ('ttgPerformerConfig') and the mocks,
and returns the bot's @Update -> IO ()@ action — normally your production
update-driver with the test performer substituted for the production performer
(e.g. via 'LazyCircus.Testing.Performer.runWithConfig', or
'LazyCircus.Testing.Performer.runWithMocks' if you want the all-mocked default).
That is how the test runs the bot's ordinary script with Telegram\/AI\/mail
mocked.

= Runtime guard

Before starting the headless bot, 'tgTest' checks that the supplied
'TestConfig' mocks Telegram ('tcTelegram' == 'Mocked'). If Telegram is requested
as 'Real', it throws 'TgTestConfigError' immediately: 'tgTest' observes bot
replies exclusively through the STM outgoing mailbox, which a real Telegram API
never populates, so a real-Telegram run would hang forever on the first
@waitFor*@. AI and Mail MAY still be 'Real' inside 'tgTest' — only Telegram is
required to be mocked.

= Teardown / quiescence

'runHeadlessBot' dispatches each update fire-and-forget via @asyncLink@; those
per-update threads are NOT cancelled when the drain loop is cancelled (a known
library limitation). To keep the 'Mailboxes' snapshot deterministic and to avoid
an in-flight action thread touching the app's DB connection after the
surrounding teardown, 'tgTest' waits for the update queue to drain AND for the
in-flight action count to reach zero before it cancels the drain loop and
snapshots. A bounded 'quiescenceTimeout' guards against an indefinite hang. A
short grace covers the microsecond dequeue→spawn window of @asyncLink@.

PRE-CONTRACT: @buildAction@ wires the test performer against the supplied
@Mocks@, and its returned action is safe to run concurrently (the runner
dispatches updates fire-and-forget). 'ttgPerformerConfig' MUST set
'tcTelegram' = 'Mocked' (otherwise 'TgTestConfigError' is thrown).
POST-CONTRACT: The headless drain loop is cancelled; the returned 'Mailboxes'
reflect all side effects observable once in-flight work has settled.
-}
tgTest ::
    TgTestConfig ->
    (TestConfig -> Mocks serviceLib -> IO (Update -> IO ())) ->
    TelegramTestScript a ->
    IO (Mailboxes, Either TgTestError a)
tgTest cfg buildAction script = do
    let performerCfg = ttgPerformerConfig cfg
    case tcTelegram performerCfg of
        Real ->
            throwIO $
                TgTestConfigError $
                    "tgTest observes bot replies via the STM outgoing mailbox, which real Telegram does not populate. "
                        <> "Set tcTelegram = Mocked (default) for tgTest, or use runScenarioProgram/runWithConfig for "
                        <> "real-Telegram tests. (AI and Mail may still be Real inside tgTest.)"
        Mocked -> pure ()
    mocks <- makeMocks
    runtime <- makeTestRuntime cfg mocks
    action <- buildAction performerCfg mocks
    let onActionError e = atomically $ writeTVar (ttrError runtime) (Just e)
        trackedAction update = bracketInflight (ttrInflight runtime) (action update)
    withAsync (runHeadlessBot onActionError (ttrQueue runtime) trackedAction) $ \botThread -> do
        result <- runTelegramTestScript runtime script
        -- Let pending updates drain and in-flight actions finish BEFORE
        -- cancelling, so the snapshot is deterministic and no action thread
        -- outlives the (soon-to-close) DB connection.
        waitForQuiescent runtime
        -- Cover the microsecond dequeue→spawn window in the fire-and-forget loop.
        threadDelay graceAfterQuiescence
        cancel botThread
        mailboxes <- snapshotMailboxes mocks runtime
        pure (mailboxes, result)

-- | Wrap an IO action with an in-flight counter increment/decrement so the
-- runner can wait for all fire-and-forget action threads to settle at teardown.
bracketInflight :: TVar Int -> IO a -> IO a
bracketInflight inflight =
    bracket_
        (atomically $ modifyTVar' inflight (+ 1))
        (atomically $ modifyTVar' inflight (subtract 1))

-- | Block (bounded by 'quiescenceTimeout') until no update is pending in the
-- queue and no action thread is in flight, so the snapshot and the surrounding
-- teardown cannot race a producer.
waitForQuiescent :: TgTestRuntime -> IO ()
waitForQuiescent runtime = do
    delay <- registerDelay quiescenceTimeout
    atomically $ do
        expired <- readTVar delay
        if expired
            then pure ()
            else do
                isEmpty <- isEmptyTBQueue (ttrQueue runtime)
                n <- readTVar (ttrInflight runtime)
                unless (isEmpty && n == 0) retry

-- | Drain the remaining mailbox + deferred buffer and count captured async work
-- into the final 'Mailboxes' snapshot.
snapshotMailboxes :: Mocks serviceLib -> TgTestRuntime -> IO Mailboxes
snapshotMailboxes mocks runtime = do
    remainingMail <- readOutgoingMailbox mocks
    deferredMsgs <- readTVarIO (ttrDeferred runtime)
    schedCount <- length <$> readScheduledScenarios mocks
    pure
        Mailboxes
            { mbOutgoing = deferredMsgs <> remainingMail
            , mbScheduledScenarioCount = schedCount
            }

-- | Upper bound (microseconds) 'tgTest' waits for pending updates and in-flight
-- action threads to settle before snapshotting. Generous relative to the mocked
-- test workload (AI is a no-op, DB writes are sub-millisecond) so it never trips
-- in practice; it exists only to guarantee 'tgTest' cannot hang on a stuck action.
quiescenceTimeout :: Int
quiescenceTimeout = 5_000_000

-- | Tiny grace (microseconds) after the quiescence gate, covering the
-- dequeue→spawn window of @asyncLink@. Microsecond window vs. millisecond grace.
graceAfterQuiescence :: Int
graceAfterQuiescence = 100_000

--------------------------------------------------------------------------------
-- Sending fake user input
--------------------------------------------------------------------------------

-- | Send a text message from the default user in the default chat; returns the
-- update's 'UpdateId' and the 'MessageId' of the sent user message (suitable for
-- passing to 'waitForReaction').
sendMessage :: Text -> TelegramTestScript (UpdateId, MessageId)
sendMessage = sendMessageByUser defaultTestUserId defaultTestChatId

-- | Send a text message from a specific user in a specific chat; returns the
-- update's 'UpdateId' and the 'MessageId' of the sent user message (suitable for
-- passing to 'waitForReaction').
sendMessageByUser :: UserId -> ChatId -> Text -> TelegramTestScript (UpdateId, MessageId)
sendMessageByUser userId chatId txt = do
    rt <- ttsAsk
    upd <- liftIO $ mkTextUpdateByUser (ttrFactory rt) userId chatId txt
    feedAndReturn rt upd

-- | Send a text message in a specific chat from the default user; returns the
-- update's 'UpdateId' and the 'MessageId' of the sent user message (suitable for
-- passing to 'waitForReaction').
sendMessageIn :: ChatId -> Text -> TelegramTestScript (UpdateId, MessageId)
sendMessageIn chatId txt = sendMessageByUser defaultTestUserId chatId txt

-- | Send a file upload from the default user in the default chat; returns the
-- update's 'UpdateId' and the 'MessageId' of the sent user message (suitable for
-- passing to 'waitForReaction').
sendFile :: FileId -> TelegramTestScript (UpdateId, MessageId)
sendFile = sendFileByUser defaultTestUserId defaultTestChatId

-- | Send a file upload from a specific user in a specific chat; returns the
-- update's 'UpdateId' and the 'MessageId' of the sent user message (suitable for
-- passing to 'waitForReaction').
sendFileByUser :: UserId -> ChatId -> FileId -> TelegramTestScript (UpdateId, MessageId)
sendFileByUser userId chatId fileId = do
    rt <- ttsAsk
    upd <- liftIO $ mkFileUpdate (ttrFactory rt) userId chatId fileId
    feedAndReturn rt upd

-- | Press an inline-keyboard button (a @callback_query@) attached to a message
-- the bot previously sent, from the default user/chat.
sendKeypress :: MessageId -> Text -> TelegramTestScript UpdateId
sendKeypress = sendKeypressByUser defaultTestUserId defaultTestChatId

-- | Press an inline-keyboard button from a specific user/chat.
sendKeypressByUser :: UserId -> ChatId -> MessageId -> Text -> TelegramTestScript UpdateId
sendKeypressByUser userId chatId targetMsgId cbData = do
    rt <- ttsAsk
    upd <- liftIO $ mkCallbackQueryUpdate (ttrFactory rt) userId chatId targetMsgId cbData
    feedAndReturnId rt upd

-- | Feed a constructed update into the headless queue and return its 'UpdateId'.
feedAndReturnId :: TgTestRuntime -> Update -> TelegramTestScript UpdateId
feedAndReturnId rt upd = do
    liftIO $ feedUpdates (ttrQueue rt) [upd]
    pure (updateUpdateId upd)

-- | Feed a constructed update and return both its 'UpdateId' and the
-- 'MessageId' of the user message it carries. The 'MessageId' is extracted
-- from the update value itself (via 'updateMessage' / 'messageMessageId'),
-- not from the factory invariant, so it stays correct regardless of how the
-- factory assigns ids.
-- PRE-CONTRACT: the update must carry a @message@ (as all message-sending
-- builders do); a message-less update (e.g. a callback_query) aborts the DSL
-- with 'TgTestGuardFailed' — use 'feedAndReturnId' for those.
feedAndReturn :: TgTestRuntime -> Update -> TelegramTestScript (UpdateId, MessageId)
feedAndReturn rt upd = do
    liftIO $ feedUpdates (ttrQueue rt) [upd]
    let uid = updateUpdateId upd
    mid <- case updateMessage upd of
        Just msg -> pure (messageMessageId msg)
        Nothing  -> ttsThrow $ TgTestGuardFailed
            "feedAndReturn: update carries no message; cannot derive a MessageId \
            \(use feedAndReturnId for callback_query / message-less updates)"
    pure (uid, mid)

--------------------------------------------------------------------------------
-- Waiting for bot replies
--------------------------------------------------------------------------------

-- | Wait for @n@ text replies in the default chat, earliest-first.
waitForReplies :: Int -> TelegramTestScript [Text]
waitForReplies n = replicateM n waitForReply

-- | Wait for a single text reply in the default chat.
waitForReply :: TelegramTestScript Text
waitForReply = waitForReplyIn defaultTestChatId

-- | Wait for a single text reply in a specific chat.
waitForReplyIn :: ChatId -> TelegramTestScript Text
waitForReplyIn chatId = do
    om <- waitForMatching (isTextReplyTo chatId) "a text reply"
    pure (fromMaybe "" (omText om))

-- | Wait for a text reply carrying an inline keyboard in the default chat;
-- returns the reply text and the bot-assigned message id (for 'sendKeypress').
waitForReplyWithKeyboard :: TelegramTestScript (Text, MessageId)
waitForReplyWithKeyboard = waitForReplyWithKeyboardIn defaultTestChatId

-- | 'waitForReplyWithKeyboard' for a specific chat.
waitForReplyWithKeyboardIn :: ChatId -> TelegramTestScript (Text, MessageId)
waitForReplyWithKeyboardIn chatId = do
    om <- waitForMatching (isKeyboardReplyTo chatId) "a reply with a keyboard"
    let msgId = fromMaybe (MessageId (-1)) (omMessageId om)
    pure (fromMaybe "" (omText om), msgId)

-- | Wait for a reaction the bot set on the given message id.
waitForReaction :: MessageId -> TelegramTestScript ()
waitForReaction targetId =
    void $
        waitForMatching
            (\om -> omKind om == OutSetReaction && omMessageId om == Just targetId)
            ("a reaction on message " <> tshow targetId)

{- | Wait for a document reply from the bot.

Returns the 'FileId' the bot would have sent. NOTE: the MVP mailbox capture does
not retain the full 'Telegram.Bot.API.Methods.SendDocument.SendDocumentRequest',
so the returned id is a stable placeholder rather than the bot's real file id;
this op is therefore suitable for /ordering/ assertions (\"the bot sent a file
after I uploaded one\") but not for file-content correlation.
-}
waitForFile :: TelegramTestScript FileId
waitForFile = do
    void $
        waitForMatching
            (\om -> omKind om == OutSendDocument)
            "a document reply"
    pure (FileId "tgTest-waited-document")

--------------------------------------------------------------------------------
-- Assertions and control
--------------------------------------------------------------------------------

-- | Abort with 'TgTestGuardFailed' unless the predicate holds.
guard :: Bool -> TelegramTestScript ()
guard ok = guardWith "guard condition was false" ok

-- | 'guard' with a caller-supplied reason included in the 'TgTestError'.
guardWith :: Text -> Bool -> TelegramTestScript ()
guardWith _ True = pure ()
guardWith reason False = ttsThrow (TgTestGuardFailed reason)

-- | Run a sub-program with a different @waitFor*@ timeout (microseconds).
withTimeout :: Int -> TelegramTestScript a -> TelegramTestScript a
withTimeout us =
    ttsLocal (\rt -> rt{ttrConfig = (ttrConfig rt){ttgTimeout = us}})

--------------------------------------------------------------------------------
-- Lower-level building blocks
--------------------------------------------------------------------------------

{- | Block until an outgoing message satisfying the predicate is observed, then
return it (consuming it from the mailbox).

This is the single primitive every @waitFor*@ op is built on. It implements the
brief's mailbox semantics:

* /Filtering/: non-matching messages are moved to a deferred buffer and offered
  to the next wait, so a multi-chat script can wait selectively.
* /STM wake-up/: the wait blocks via 'retry', so the performer's mailbox write
  (committed in one 'atomically') wakes it deterministically — there is no
  polling. The 'registerDelay' timer and the action-error channel are also read
  in the same transaction so a timeout or a bot-action exception wakes it too.
* /Leave-on-mismatch/: deferred messages are preserved in FIFO order.

POST-CONTRACT: On 'Right', the matched message has been removed from the
observable mailbox; on 'Left', the mailbox is untouched.
-}
waitForMatching :: (OutgoingMessage -> Bool) -> Text -> TelegramTestScript OutgoingMessage
waitForMatching predicate awaitDesc = do
    rt <- ttsAsk
    let mailbox = ttrMailbox rt
        deferredVar = ttrDeferred rt
        errVar = ttrError rt
        timeoutUs = ttgTimeout (ttrConfig rt)
        awaitTx delay = do
            mErr <- readTVar errVar
            case mErr of
                Just e -> pure (Left (TgTestActionError e))
                Nothing -> do
                    expired <- readTVar delay
                    if expired
                        then pure (Left (TgTestTimeout awaitDesc))
                        else do
                            available <- flushTBQueue mailbox
                            buffered <- readTVar deferredVar
                            case findMatch predicate (buffered <> available) of
                                Just (match, rest) -> do
                                    writeTVar deferredVar rest
                                    pure (Right match)
                                Nothing -> retry
    result <-
        liftIO $ do
            delay <- registerDelay timeoutUs
            atomically (awaitTx delay)
    case result of
        Left e -> ttsThrow e
        Right a -> pure a

--------------------------------------------------------------------------------
-- Internal helpers
--------------------------------------------------------------------------------

-- | Predicate: an outgoing message is a text reply addressed to the given chat.
isTextReplyTo :: ChatId -> OutgoingMessage -> Bool
isTextReplyTo chatId om =
    omKind om == OutSendMessage && omChatId om == Just chatId

-- | Predicate: an outgoing message is a text reply to the given chat with a keyboard.
isKeyboardReplyTo :: ChatId -> OutgoingMessage -> Bool
isKeyboardReplyTo chatId om = isTextReplyTo chatId om && isJust (omReplyMarkup om)

-- | Find the first list element satisfying the predicate, returning it together
-- with the remaining elements in their original order.
findMatch :: (a -> Bool) -> [a] -> Maybe (a, [a])
findMatch predicate = go []
  where
    go _ [] = Nothing
    go acc (x : rest)
        | predicate x = Just (x, revAppend acc rest)
        | otherwise = go (x : acc) rest
    revAppend acc rest = foldl' (flip (:)) rest acc
