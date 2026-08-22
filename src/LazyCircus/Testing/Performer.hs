{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Mock-backed performer shell for tests that mirrors production environment projection.
--
-- PURPOSE: Provide a test double for the production performer that captures side
-- effects (Telegram sends, mail sends, log emissions, async scenario scheduling)
-- into inspectable mock state while delegating real dependencies (DB connections,
-- config, mail construction) to the production 'DefaultApp'.
-- SCOPE: Mock state types, test interpreter runner, scenario/script dispatch,
-- mock factory helpers, and captured-effect readers.
module LazyCircus.Testing.Performer (
    OnSendMessageRequest,
    TgMock (..),
    MailMock (..),
    AiMock (..),
    Mocks (..),
    Mode (..),
    TestConfig (..),
    defaultTestConfig,
    EnvWithMocks (..),
    TestInterpreter,
    OutgoingMessage (..),
    OutgoingKind (..),
    runTestInterpreter,
    changeEnv,
    runScript,
    runScenarioProgram,
    runDBWithMockLogging,
    runTelegramScript,
    createTgMock,
    createSimpleTgMock,
    addTgDownloads,
    createSimpleMailMock,
    createAiMock,
    createSimpleAiMock,
    makeMocks,
    makeMocksWithAi,
    runInsideWithMocks,
    runWithMocks,
    runInsideWithDefaultMocks,
    runWithDefaultMocks,
    runInsideWithAiMocks,
    runWithAiMocks,
    runWithConfigEngine,
    runWithConfig,
    runWithDefaultConfig,
    runInsideWithConfig,
    runInsideWithDefaultConfig,
    discardMocks,
    readTgRequests,
    readScheduledTgRequests,
    readOutgoingMailbox,
    readLog,
    readLogWithContext,
    readSentMails,
    readAiRequests,
    readScheduledScenarios,
)
where

import Data.Pool (Pool, withResource)
import Database.PostgreSQL.Simple qualified as Simple
import LazyCircus.AI (HasAIMethods (..), askAIContinuing, solveWithAgentLoopContinuing)
import LazyCircus.App.Default qualified as App
import LazyCircus.App.Log
import LazyCircus.App.Service (HasServiceLib (..), HasToolCallExec (..), HasToolDescriptions (..), callViaServiceLib)
import LazyCircus.AsyncWorker.Types (HasScheduledActions (..))
import LazyCircus.DB.Types (PgDB)
import LazyCircus.DB.WithConnection (AppWithConnection (..))
import LazyCircus.Mail qualified as Mail
import LazyCircus.Performer.Default (AppWithClientEnv (..))
import LazyCircus.Performer.Default qualified as Default
import LazyCircus.Scenario
    ( DbMode (..)
    , KnownHowToEval (..)
    , ScenarioPerformer (..)
    , ScenarioProgram
    , run
    )

import Control.Concurrent.STM (retry)
import GHC.Stack (HasCallStack, callStack)
import LazyCircus.Scene.AI.Class (AILangPerformer (..), runAI)
import LazyCircus.Scene.DB.Class (runDB)
import LazyCircus.Scene.DB.Lang (DBScript)
import LazyCircus.Scene.HTTP.Class (HTTPPerformer (..), runHTTP)
import LazyCircus.Scene.Log (timedAndLog)
import LazyCircus.Scene.Mail.Class (MailScriptPerformer (..), runMail)
import LazyCircus.Scene.Telegram.Class (TelegramScriptPerformer (..), runTelegram)
import LazyCircus.Scene.Telegram.Lang (TelegramScript)
import LazyCircus.Script (Script (..))
import LazyCircus.Telegram qualified as TG
import LazyCircus.Telegram.Default qualified as TGDefault
import LazyCircus.Telegram.Types (AppWithBotEnv (..), WithImportance (..))
import Network.Mail.Mime (Address, Mail)
import OpenAI.V1 qualified as V1
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.Usage (Usage (..))
import RIO
import RIO.ByteString qualified as BS
import RIO.HashMap qualified as HM
import RIO.Map qualified as M
import RIO.Process (HasProcessContext (..))
import RIO.Time (getCurrentTime)
import RIO.Vector qualified as V
import Servant.Client (mkClientEnv, runClientM)
import Telegram.Bot.API (ChatId, Message, MessageId, Response, SendMessageRequest, SomeChatId (..), SomeReplyMarkup, editMessageTextChatId, editMessageTextMessageId, editMessageTextText, messageMessageId, responseResult, sendDocumentCaption, sendDocumentChatId, sendMessageChatId, sendMessageReplyMarkup, sendMessageText, setMessageReactionRequestChatId, setMessageReactionRequestMessageId)
import Telegram.Bot.API.Types (File (..), FileId (..), MessageId (..))

-- | Response factory used by the Telegram mock to derive a reply from one outgoing request.
type OnSendMessageRequest = WithImportance SendMessageRequest -> Response Message

-- | Discriminator tagging which Telegram operation produced an 'OutgoingMessage' capture.
data OutgoingKind
    = OutSendMessage
    -- ^ a @sendMessage@ reply
    | OutSendDocument
    -- ^ a @sendDocument@ reply
    | OutSetReaction
    -- ^ a @setMessageReaction@ request
    | OutEditMessage
    -- ^ an @editMessageText@ request
    | OutDeleteMessage
    -- ^ a @deleteMessage@ request
    deriving (Eq, Show)

-- | A captured outgoing Telegram side effect, observable by the @tgTest@ DSL.
--
-- The mock publishes one 'OutgoingMessage' to the 'outgoingMailbox' 'STM.TBQueue'
-- for every Telegram operation that produces user-visible traffic, so the test
-- DSL's @waitFor*@ operations can observe replies deterministically through STM.
-- The 'omMessageId' is the /assigned/ incremental id for @sendMessage@\/@sendDocument@
-- (see 'tgMockMessageIdCounter'), or the /target/ id for
-- @setMessageReaction@\/@editMessageText@\/@deleteMessage@.
data OutgoingMessage = OutgoingMessage
    { omKind :: OutgoingKind
    -- ^ which Telegram operation produced this capture
    , omChatId :: Maybe ChatId
    -- ^ resolved numeric target chat id ('Nothing' for username-targeted sends)
    , omText :: Maybe Text
    -- ^ message text, when the operation carries one
    , omMessageId :: Maybe MessageId
    -- ^ assigned incremental id (sendMessage/sendDocument) or target id (reaction/edit)
    , omReplyMarkup :: Maybe SomeReplyMarkup
    -- ^ inline keyboard attached to a sent message, if any
    }

-- | Manual 'Show' for 'OutgoingMessage' because 'SomeReplyMarkup' has no 'Show'
-- instance; the opaque markup is rendered as a placeholder.
instance Show OutgoingMessage where
    show om =
        "OutgoingMessage{ omKind = " <> show (omKind om)
            <> ", omChatId = " <> show (omChatId om)
            <> ", omText = " <> show (omText om)
            <> ", omMessageId = " <> show (omMessageId om)
            <> ", omReplyMarkup = " <> maybe "Nothing" (const "(markup)") (omReplyMarkup om)
            <> " }"

-- | Telegram mock state used by the test performer.
data TgMock = TgMock
    { sendMessageResponses :: SomeRef [OnSendMessageRequest]
    -- ^ queued canned responses consumed by 'sendMessage'
    , sendMessageRequests :: SomeRef [WithImportance SendMessageRequest]
    -- ^ captured outgoing immediate Telegram sends
    , scheduledMessageRequests :: SomeRef [SendMessageRequest]
    -- ^ captured deferred Telegram sends requested via 'scheduleMessages'
    , downloadableFiles :: SomeRef (HashMap Text ByteString)
    -- ^ canned file content keyed by the file id text, served by mocked
    -- 'getFile'' (metadata) and 'downloadFile'' (content); inject via
    -- 'addTgDownloads' or the 'createTgMock' argument. Keyed by 'Text' rather
    -- than 'FileId' because 'FileId' has no 'Hashable' instance.
    , defaultResponse :: Response Message
    -- ^ fallback response used when no canned response is queued
    , outgoingMailbox :: TBQueue OutgoingMessage
    -- ^ STM mailbox of every outgoing Telegram side effect, drained by the @tgTest@ DSL's @waitFor*@ ops
    , tgMockMessageIdCounter :: TVar Int
    -- ^ incremental counter stamping unique 'MessageId's onto mock send responses
    }

-- | Mail mock state used by the test performer.
data MailMock = MailMock
    { sentMails :: SomeRef [Mail]
    -- ^ captured outgoing mail values
    }

-- | AI mock state used by the test performer to inject canned chat-completion
-- responses and capture rendered requests. Mirrors the FIFO-dequeue + capture-log
-- structure of 'TgMock', but for the OpenAI transport seam.
data AiMock = AiMock
    { aiResponses :: SomeRef [Chat.ChatCompletionObject]
    -- ^ queued canned completions consumed FIFO by 'createChatCompletion'
    , aiRequests :: SomeRef [Chat.CreateChatCompletion]
    -- ^ captured rendered requests (prepend-on-write, reverse-on-read)
    }

-- | Aggregate capture state collected while a test scenario runs.
data Mocks serviceLib = Mocks
    { tgMock :: TgMock
    -- ^ Telegram request and response capture
    , appLog :: SomeRef [AppLogMsg]
    -- ^ captured log payloads without context
    , appLogWithContext :: SomeRef [AppLogMsgWithContext]
    -- ^ captured log payloads with context and call site
    , mockLogQueue :: LogQueue
    -- ^ private queue used to capture logs through the standard log-language path
    , mailMock :: MailMock
    -- ^ captured mail sends
    , aiMock :: AiMock
    -- ^ AI request capture and canned-response queue
    , scheduledScenarios :: SomeRef [ScenarioProgram Script serviceLib ()]
    -- ^ captured async control programs requested through 'runAsync' ('tcAsync = Mocked')
    , asyncInflight :: !(TVar Int)
    -- ^ count of 'tcAsync = Real' spawned async workers currently running; awaited at
    -- 'runWithConfigEngine' teardown so spawned work settles before the run returns
    }

-- | Runtime mode controlling whether a test sub-language is mocked or real.
data Mode = Mocked | Real
    deriving (Eq, Show)

-- | Per-sub-language configuration for the test performer.
-- Controls whether Telegram, AI, Mail-send, and async work are mocked
-- (capture/intercept) or real (delegate to production implementations).
data TestConfig = TestConfig
    { tcTelegram :: !Mode
    -- ^ Telegram send/receive mode: Mocked = mailbox capture, Real = TG.* API calls
    , tcAI :: !Mode
    -- ^ AI mode: Mocked = transport intercept via buildMockAiMethods, Real = real OpenAI client
    , tcMailSend :: !Mode
    -- ^ Mail send mode: Mocked = capture in sentMails ref, Real = SMTP via Mail.sendMail
    , tcAsync :: !Mode
    -- ^ 'LazyCircus.Scenario.runAsync' mode: Mocked = capture scenario in
    -- 'scheduledScenarios' (assert via 'readScheduledScenarios'); Real = spawn
    -- the scenario on a background thread so its side effects genuinely run and
    -- land in the usual capture buffers / outgoing mailbox (no capture in
    -- 'scheduledScenarios')
    }

-- | Default config: everything that can be mocked IS mocked (backward-compatible).
defaultTestConfig :: TestConfig
defaultTestConfig = TestConfig{tcTelegram = Mocked, tcAI = Mocked, tcMailSend = Mocked, tcAsync = Mocked}

-- | Test runtime environment that combines mocks with the real application environment.
data EnvWithMocks serviceLib = EnvWithMocks
    { mocks :: Mocks serviceLib
    -- ^ mutable capture state for the current test run
    , defaultApp :: App.DefaultApp serviceLib
    -- ^ real runtime dependencies used for DB access, config, and mail construction
    , testConfig :: TestConfig
    -- ^ per-sub-language mock/real mode selection
    }

-- | Thin RIO-backed shell used internally by the test performer.
newtype TestPerformer env a = TestPerformer
    { unTestPerformer :: RIO env a
    }
    deriving
        ( Applicative
        , Functor
        , Monad
        , MonadIO
        , MonadReader env
        , MonadUnliftIO
        )

-- | Public test performer specialized to the combined test environment.
type TestInterpreter serviceLib a = TestPerformer (EnvWithMocks serviceLib) a

-- | Unwrap a test interpreter action into the underlying 'RIO' program.
-- POST-CONTRACT: The returned action reads mock state from the same 'EnvWithMocks' environment.
runTestInterpreter :: TestInterpreter serviceLib a -> RIO (EnvWithMocks serviceLib) a
runTestInterpreter = unTestPerformer

-- | Delegates structured logging context updates to the wrapped DefaultApp.
instance HasLoggingContext (EnvWithMocks serviceLib) where
    logContextL = lens defaultApp (\env app -> env{defaultApp = app}) . logContextL

-- | Directs test logs into the mock-private queue instead of the production queue.
instance HasLogQueue (EnvWithMocks serviceLib) where
    logQueueL = lens (mockLogQueue . mocks) updateQueue
      where
        updateQueue env queue = env{mocks = testMocks{mockLogQueue = queue}}
          where
            testMocks = mocks env

-- | Delegates base RIO logging to the wrapped DefaultApp.
instance HasLogFunc (EnvWithMocks serviceLib) where
    logFuncL = lens defaultApp (\env app -> env{defaultApp = app}) . logFuncL

-- | Delegates generic logging to the wrapped DefaultApp.
instance HasGLogFunc (EnvWithMocks serviceLib) where
    type GMsg (EnvWithMocks serviceLib) = GMsg (App.DefaultApp serviceLib)
    gLogFuncL = lens defaultApp (\env app -> env{defaultApp = app}) . gLogFuncL

-- | Delegates process-context access to the wrapped DefaultApp.
instance HasProcessContext (EnvWithMocks serviceLib) where
    processContextL = lens defaultApp (\env app -> env{defaultApp = app}) . processContextL

-- | Delegates primary PostgreSQL pool access to the wrapped DefaultApp.
instance App.HasPgPool (EnvWithMocks serviceLib) where
    pgPoolL = lens defaultApp (\env app -> env{defaultApp = app}) . App.pgPoolL

-- | Delegates read-only PostgreSQL pool access to the wrapped DefaultApp.
instance App.HasPgPoolReadOnly (EnvWithMocks serviceLib) where
    pgPoolReadOnlyL = lens defaultApp (\env app -> env{defaultApp = app}) . App.pgPoolReadOnlyL

-- | Delegates JWT settings access to the wrapped DefaultApp.
instance App.HasJWTSettings (EnvWithMocks serviceLib) where
    jwtSettingsL = lens defaultApp (\env app -> env{defaultApp = app}) . App.jwtSettingsL

-- | Delegates configured bot environments to the wrapped DefaultApp.
instance App.HasBotEnvs (EnvWithMocks serviceLib) where
    botEnvsL = lens defaultApp (\env app -> env{defaultApp = app}) . App.botEnvsL

-- | Delegates extra context access to the wrapped DefaultApp.
instance App.HasExtraContext (EnvWithMocks serviceLib) where
    extraContextL = lens defaultApp (\env app -> env{defaultApp = app}) . App.extraContextL

-- | Delegates SMTP credentials access to the wrapped DefaultApp.
instance App.HasMailCreds (EnvWithMocks serviceLib) where
    mailCredsL = lens defaultApp (\env app -> env{defaultApp = app}) . App.mailCredsL

-- | Delegates scheduled-actions access to the wrapped DefaultApp.
instance HasScheduledActions Script serviceLib (EnvWithMocks serviceLib) where
    scheduledActionsL = lens defaultApp (\env app -> env{defaultApp = app}) . scheduledActionsL

-- | Delegates AI-method access to the wrapped DefaultApp.
instance HasAIMethods (EnvWithMocks serviceLib) where
    aiMethodsL = lens defaultApp (\env app -> env{defaultApp = app}) . aiMethodsL

-- | Delegates service-library access to the wrapped DefaultApp.
instance HasServiceLib (EnvWithMocks serviceLib) serviceLib where
    serviceLibL = lens defaultApp (\env app -> env{defaultApp = app}) . serviceLibL

-- | Delegates tool-description access to the wrapped DefaultApp.
instance HasToolDescriptions (EnvWithMocks serviceLib) where
    toolDescriptionsL = lens defaultApp (\env app -> env{defaultApp = app}) . toolDescriptionsL

-- | Delegates tool-call execution access to the wrapped DefaultApp.
instance HasToolCallExec (EnvWithMocks serviceLib) where
    toolCallExecL = lens defaultApp (\env app -> env{defaultApp = app}) . toolCallExecL

-- | Delegates HTTP manager access to the wrapped DefaultApp.
instance App.HasHttpManager (EnvWithMocks serviceLib) where
    httpManagerL = lens defaultApp (\env app -> env{defaultApp = app}) . App.httpManagerL

-- | Re-target a test action to an outer environment via a pure projection.
changeEnv :: (outer -> inner) -> TestPerformer inner a -> TestPerformer outer a
changeEnv f (TestPerformer action) = TestPerformer (mapRIO f action)

-- | Captures Telegram operations while relying on the projected bot environment for bot metadata.
--
-- Each IO method reads 'tcTelegram' from 'testConfig' and branches:
--
--   * @Mocked@ — current mailbox-capture behavior (publishes an 'OutgoingMessage',
--     stamps a fresh incremental id, dequeues a canned response).
--   * @Real@   — delegates to the production 'TG.*' client call wrapped in
--     'timedAndLog' (mirrors 'LazyCircus.Performer.Default').
instance TelegramScriptPerformer (TestPerformer (AppWithBotEnv (EnvWithMocks serviceLib))) where
    getFile' fid = do
        mode <- asks (tcTelegram . testConfig . app)
        case mode of
            Mocked -> getFileMock fid
            Real -> timedAndLog "Telegram" "GetFile" $ TG.getFile fid
    downloadFile' f = do
        mode <- asks (tcTelegram . testConfig . app)
        case mode of
            Mocked -> do
                tg <- askTgMock
                downloads <- readSomeRef (downloadableFiles tg)
                case HM.lookup (fileIdText (fileFileId f)) downloads of
                    Just bytes -> pure bytes
                    Nothing -> throwString $ "LazyCircus.Testing.Performer.downloadFile': no canned download staged for " <> show (fileFileId f)
            Real -> timedAndLog "Telegram" "DownloadFile" $ TG.downloadFile f
    getBotName' = TG.getBotName
    sendMessage' request = do
        mode <- asks (tcTelegram . testConfig . app)
        case mode of
            Mocked -> do
                logTgRequests [request]
                tg <- askTgMock
                let req = importancePayload request
                assignedId <- liftIO $ publishWithFreshId tg $ \mid ->
                    outgoingSendMessage
                        mid
                        (someChatIdToChatId (sendMessageChatId req))
                        (Just (sendMessageText req))
                        (sendMessageReplyMarkup req)
                resp <- dequeueTgResponse request
                pure (stampMessageId assignedId resp)
            Real -> timedAndLog "Telegram" "SendMessage" $ TG.sendMessage request
    scheduleMessages' = \requests -> do
        mode <- asks (tcTelegram . testConfig . app)
        case mode of
            Mocked -> logScheduledTgRequests requests
            Real -> timedAndLog "Telegram" "ScheduleMessages" $ TG.scheduleMessages requests
    setBotCommands' cmd = do
        mode <- asks (tcTelegram . testConfig . app)
        case mode of
            Mocked -> pure ()
            Real -> timedAndLog "Telegram" "SetBotCommands" $ TG.setBotCommands cmd
    setMessageReaction' req = do
        mode <- asks (tcTelegram . testConfig . app)
        case mode of
            Mocked -> do
                tg <- askTgMock
                liftIO $
                    publishOutgoing tg $
                        OutgoingMessage
                            { omKind = OutSetReaction
                            , omChatId = someChatIdToChatId (setMessageReactionRequestChatId req)
                            , omText = Nothing
                            , omMessageId = Just (setMessageReactionRequestMessageId req)
                            , omReplyMarkup = Nothing
                            }
            Real -> timedAndLog "Telegram" "SetMessageReaction" $ TG.setMessageReaction req
    answerCallbackQuery' req = do
        mode <- asks (tcTelegram . testConfig . app)
        case mode of
            Mocked -> pure ()
            Real -> timedAndLog "Telegram" "AnswerCallbackQuery" $ TG.answerCallbackQuery req
    editMessageText' req = do
        mode <- asks (tcTelegram . testConfig . app)
        case mode of
            Mocked -> do
                tg <- askTgMock
                liftIO $
                    publishOutgoing tg $
                        OutgoingMessage
                            { omKind = OutEditMessage
                            , omChatId = someChatIdToChatId =<< editMessageTextChatId req
                            , omText = Just (editMessageTextText req)
                            , omMessageId = editMessageTextMessageId req
                            , omReplyMarkup = Nothing
                            }
                pure Nothing
            Real -> timedAndLog "Telegram" "EditMessageText" $ TG.editMessageText req
    deleteMessage' chatId messageId = do
        mode <- asks (tcTelegram . testConfig . app)
        case mode of
            Mocked -> do
                tg <- askTgMock
                liftIO $
                    publishOutgoing tg $
                        OutgoingMessage
                            { omKind = OutDeleteMessage
                            , omChatId = Just chatId
                            , omText = Nothing
                            , omMessageId = Just messageId
                            , omReplyMarkup = Nothing
                            }
            Real -> timedAndLog "Telegram" "DeleteMessage" $ TG.deleteMessage chatId messageId
    sendDocument' req = do
        mode <- asks (tcTelegram . testConfig . app)
        case mode of
            Mocked -> do
                tg <- askTgMock
                assignedId <- liftIO $ publishWithFreshId tg $ \mid ->
                    OutgoingMessage
                        { omKind = OutSendDocument
                        , omChatId = someChatIdToChatId (sendDocumentChatId req)
                        , omText = sendDocumentCaption req
                        , omMessageId = Just mid
                        , omReplyMarkup = Nothing
                        }
                resp <- asks (defaultResponse . tgMock . mocks . app)
                pure (stampMessageId assignedId resp)
            Real -> timedAndLog "Telegram" "SendDocument" $ TG.sendDocument req

-- | Project the current 'TgMock' out of the bot-environment-wrapped test environment.
askTgMock :: TestPerformer (AppWithBotEnv (EnvWithMocks serviceLib)) TgMock
askTgMock = asks (tgMock . mocks . app)

-- | Build an 'OutSendMessage' 'OutgoingMessage' carrying an explicit assigned id.
outgoingSendMessage :: MessageId -> Maybe ChatId -> Maybe Text -> Maybe SomeReplyMarkup -> OutgoingMessage
outgoingSendMessage mid chatId text markup =
    OutgoingMessage
        { omKind = OutSendMessage
        , omChatId = chatId
        , omText = text
        , omMessageId = Just mid
        , omReplyMarkup = markup
        }

-- | Publish an 'OutgoingMessage' that already carries its own id (a reaction or
-- an edit — operations with no returned 'Message' to stamp).
publishOutgoing :: TgMock -> OutgoingMessage -> IO ()
publishOutgoing tg msg = atomically $ writeTBQueue (outgoingMailbox tg) msg

{- | Assign a fresh incremental 'MessageId', build the 'OutgoingMessage' from it,
and publish — all in a SINGLE 'atomically'.

Keeping the counter increment and the queue write in one transaction is what
makes the @tgTest@ DSL's @waitFor*@ deterministic: a reader blocked in
'atomically' on the mailbox is re-evaluated the moment this transaction commits,
so it wakes with the id and the message arriving together (no id-without-message
window, no lost wake-up).
-}
publishWithFreshId :: TgMock -> (MessageId -> OutgoingMessage) -> IO MessageId
publishWithFreshId tg mkMsg = atomically $ do
    n <- readTVar (tgMockMessageIdCounter tg)
    writeTVar (tgMockMessageIdCounter tg) (n + 1)
    let msgId = MessageId (fromIntegral n)
    writeTBQueue (outgoingMailbox tg) (mkMsg msgId)
    pure msgId

-- | Stamp an assigned 'MessageId' onto a mock 'Response Message' so callers can
-- correlate by 'messageMessageId' instead of the static 'defaultMessage' id (-1).
stampMessageId :: MessageId -> Response Message -> Response Message
stampMessageId msgId resp =
    resp{responseResult = (responseResult resp){messageMessageId = msgId}}

-- | Captures mail sends while reusing production mail construction.
--
-- 'sendMail'' reads 'tcMailSend' from 'testConfig' and branches:
--
--   * @Mocked@ — captures the mail into 'sentMails' via 'logMailSend'.
--   * @Real@   — delegates to SMTP via 'Mail.sendMail', wrapped in 'timedAndLog'.
--
-- 'makeMail'' always builds the mail locally via 'buildMail' (no IO either way).
instance MailScriptPerformer (TestPerformer (EnvWithMocks serviceLib)) where
    sendMail' mail = do
        mode <- asks (tcMailSend . testConfig)
        case mode of
            Mocked -> logMailSend mail
            Real -> timedAndLog "Mail" "SendMail" $ Mail.sendMail mail
    makeMail' = buildMail

-- | Drives the production AI pipeline against either a mock OpenAI transport or the real client.
--
-- Each 'askContinuing'' / 'solveWithAgentContinuing'' call reads 'tcAI' from
-- 'testConfig' and branches:
--
--   * @Mocked@ — runs the REAL 'askAIContinuing' / 'solveWithAgentLoopContinuing'
--     with 'aiMethodsL' locally overridden to 'buildMockAiMethods', which captures
--     every rendered request into 'Mocks.aiMock' and dequeues the next staged
--     'Chat.ChatCompletionObject' response FIFO. An empty queue yields
--     'emptyCompletion' (no choices), which the production decode path turns into
--     'Nothing' — preserving backward compatibility for tests that don't stage
--     responses.
--   * @Real@   — delegates to 'askAIContinuing' / 'solveWithAgentLoopContinuing'
--     WITHOUT overriding 'aiMethodsL', so the real OpenAI client from
--     'DefaultApp.aiMethods' is used. 'readAiRequests' will be empty in this mode;
--     requires a real 'aiMethods' in 'DefaultApp' (cfgAiApiKey /= Nothing).
--
-- NOTE: production AI logs ('logReasoningContent', decode-error
-- 'SensitiveLogMsg') flow to the 'DefaultApp' 'gLogFunc', NOT to the mock
-- log queue, so 'readLog' will not observe them. Use 'readAiRequests' to
-- inspect prompts/thinking/tools (Mocked mode only). Happy-path stubs
-- (valid JSON) produce no such logs.
instance AILangPerformer (TestPerformer (EnvWithMocks serviceLib)) where
    askContinuing' req conv = do
        mode <- asks (tcAI . testConfig)
        case mode of
            Mocked -> do
                base <- view aiMethodsL
                aiM <- asks (aiMock . mocks)
                local (aiMethodsL .~ buildMockAiMethods base aiM) (askAIContinuing req conv)
            Real -> askAIContinuing req conv
    solveWithAgentContinuing' req conv = do
        mode <- asks (tcAI . testConfig)
        case mode of
            Mocked -> do
                base <- view aiMethodsL
                aiM <- asks (aiMock . mocks)
                local (aiMethodsL .~ buildMockAiMethods base aiM) (solveWithAgentLoopContinuing req conv)
            Real -> solveWithAgentLoopContinuing req conv

-- | Executes servant-client actions against the real HTTP backend using the client environment.
instance HTTPPerformer (TestPerformer (AppWithClientEnv (EnvWithMocks serviceLib))) where
    runClient' act = do
        clientEnv <- asks appClientEnv
        liftIO $ runClientM act clientEnv

-- | Dispatches top-level scripts using the same environment-projection model as production.
instance KnownHowToEval Script (TestPerformer (EnvWithMocks serviceLib)) where
    evalSubScript = runScript

-- | Executes control programs in the test shell while capturing async work instead of running it.
instance ScenarioPerformer Script serviceLib (TestPerformer (EnvWithMocks serviceLib)) where
    onEvalScript = evalSubScript
    throw' = throwIO
    -- Async exceptions are re-thrown, never returned as 'Left' (mirrors the
    -- production performer). LAW: @Left@ is never an async exception.
    runSafely' scenario = do
        v <- try $ run scenario
        case v of
            Right a -> pure (Right a)
            Left e
                | Just (_ :: SomeAsyncException) <- fromException (toException e) -> throwIO e
                | otherwise -> pure (Left e)
    getDateTime' = liftIO getCurrentTime
    log' cs = sublangLog cs "Scenario"
    getExtraContext' = view App.extraContextL
    runAsync' = runAsyncTest
    runArbitraryIO' = liftIO
    callService' = callViaServiceLib
    withLogContext' values action =
        local (logContextL %~ (`putInLoggingContext` values)) (run action)

-- | Run one top-level 'Script' using the production-style test performer dispatch.
-- PRE-CONTRACT: The bot name in a 'TelegramScriptDef' must be configured in 'App.botEnvsL'.
runScript :: Script a -> TestInterpreter serviceLib a
runScript (TelegramScriptDef botName script) = runTelegramScript botName script
runScript (MailScriptDef script) = runMail script
runScript (AIScriptDef descs script) = local (toolDescriptionsL .~ descs) $ runAI script
runScript (DBScriptDef db mode script) = runDBWithMockLogging db mode script
runScript (HTTPScriptDef baseUrl scr) = do
    manager <- view App.httpManagerL
    let clientEnv = mkClientEnv manager baseUrl
    changeEnv (AppWithClientEnv clientEnv) (runHTTP scr)

-- | Run a 'ScenarioProgram' using production-style dispatch and test async semantics.
-- POST-CONTRACT: Async scenarios are captured in mock state rather than executed.
runScenarioProgram :: ScenarioProgram Script serviceLib a -> TestInterpreter serviceLib a
runScenarioProgram = run

-- | Run a DB script using the same pool-selection projection as production.
-- PRE-CONTRACT: The wrapped DefaultApp must carry a configured PostgreSQL pool
-- (see 'App.newDefaultApp'); one connection is checked out for the whole
-- script, so 'withTransaction' inside the script is safe.
runDBWithMockLogging :: PgDB db -> DbMode -> DBScript db a -> TestInterpreter serviceLib a
runDBWithMockLogging db mode script = do
    pool <- asks (selectDbPool mode)
    withRunInIO $ \runInIO ->
        withResource pool $ \conn ->
            runInIO $ changeEnv (AppWithConnection conn) (runDB db mode script)

-- | Run a Telegram script using the same bot-environment projection as production.
--
-- Branches on 'tcTelegram' from 'testConfig': the underlying performer instance
-- decides per-operation whether to mock (mailbox capture) or to call the real
-- Telegram client. Either way the bot-environment projection below is identical.
-- PRE-CONTRACT: The bot name must be present in 'App.botEnvsL'; throws 'NoBotConfigured' otherwise.
runTelegramScript :: Text -> TelegramScript a -> TestInterpreter serviceLib a
runTelegramScript botName script = do
    botEnvs <- view App.botEnvsL
    case M.lookup botName botEnvs of
        Nothing -> throwIO $ Default.NoBotConfigured botName
        Just botEnv -> changeEnv (AppWithBotEnv botEnv) (runTelegram script)

-- | Bounded capacity of the outgoing-mailbox 'TBQueue'.
-- Sized generously relative to the number of replies a single bot turn can produce
-- so that a burst of sends never blocks the performer thread on a full queue.
outgoingMailboxSize :: Natural
outgoingMailboxSize = 64

{- | Build a Telegram mock with a fallback response, optional queued send
responses, and canned downloadable file content.
POST-CONTRACT: The returned 'TgMock' has empty request logs; queued responses
are consumed FIFO by 'sendMessage'; the canned downloads are served by mocked
'getFile'' / 'downloadFile'' (inject more via 'addTgDownloads').
-}
createTgMock :: Response Message -> Maybe [OnSendMessageRequest] -> [(FileId, ByteString)] -> IO TgMock
createTgMock fallback queuedResponses downloadableContent = do
    responseQueue <- newSomeRef $ fromMaybe [] queuedResponses
    requestLog <- newSomeRef []
    scheduledLog <- newSomeRef []
    downloadsRef <- newSomeRef (HM.fromList [(fileIdText fid, bytes) | (fid, bytes) <- downloadableContent])
    mailbox <- newTBQueueIO outgoingMailboxSize
    msgIdCounter <- newTVarIO 0
    pure
        TgMock
            { sendMessageResponses = responseQueue
            , sendMessageRequests = requestLog
            , scheduledMessageRequests = scheduledLog
            , downloadableFiles = downloadsRef
            , defaultResponse = fallback
            , outgoingMailbox = mailbox
            , tgMockMessageIdCounter = msgIdCounter
            }

-- | Build a Telegram mock that always returns the standard canned message response.
createSimpleTgMock :: IO TgMock
createSimpleTgMock = createTgMock (TGDefault.defaultResponse Nothing TGDefault.defaultMessage) Nothing []

-- | Inject canned file content into a Telegram mock's download store, so mocked
-- 'getFile'' metadata and 'downloadFile'' content agree for the same 'FileId'.
-- POST-CONTRACT: Re-injecting content for the same 'FileId' overwrites the
-- earlier bytes.
addTgDownloads :: TgMock -> [(FileId, ByteString)] -> IO ()
addTgDownloads tg files =
    modifySomeRef (downloadableFiles tg) $
        HM.union (HM.fromList [(fileIdText fid, bytes) | (fid, bytes) <- files])

-- | Build an empty mail mock with no captured sends.
createSimpleMailMock :: IO MailMock
createSimpleMailMock = do
    mailLog <- newSomeRef []
    pure MailMock{sentMails = mailLog}

-- | Build an AI mock with a queue of canned completions and an empty request log.
-- POST-CONTRACT: The returned 'AiMock' has an empty request log; responses are consumed FIFO by 'buildMockAiMethods'.
createAiMock :: [Chat.ChatCompletionObject] -> IO AiMock
createAiMock responses = do
    responseQueue <- newSomeRef responses
    requestLog <- newSomeRef []
    pure
        AiMock
            { aiResponses = responseQueue
            , aiRequests = requestLog
            }

-- | Build an AI mock with no queued responses and an empty request log.
createSimpleAiMock :: IO AiMock
createSimpleAiMock = createAiMock []

-- | Allocate a fresh set of empty mocks for one test run.
makeMocks :: IO (Mocks serviceLib)
makeMocks = do
    telegramMock <- createSimpleTgMock
    logMessages <- newSomeRef []
    contextualLogMessages <- newSomeRef []
    logQueue <- newTQueueIO
    mockMail <- createSimpleMailMock
    aiMockTest <- createSimpleAiMock
    asyncLog <- newSomeRef []
    asyncCounter <- newTVarIO 0
    pure
        Mocks
            { tgMock = telegramMock
            , appLog = logMessages
            , appLogWithContext = contextualLogMessages
            , mockLogQueue = logQueue
            , mailMock = mockMail
            , aiMock = aiMockTest
            , scheduledScenarios = asyncLog
            , asyncInflight = asyncCounter
            }

-- | Run a test action inside 'RIO DefaultApp' using a caller-supplied mock set.
runInsideWithMocks :: Mocks serviceLib -> TestInterpreter serviceLib a -> RIO (App.DefaultApp serviceLib) a
runInsideWithMocks testMocks action = do
    app <- ask
    liftIO $ runWithMocks app testMocks action

-- | Upper bound (microseconds) 'runWithConfigEngine' waits for 'tcAsync = Real'
-- spawned workers to settle before draining logs and returning. Mirrors the
-- @tgTest@ 'quiescenceTimeout' rationale; on expiry the run proceeds best-effort.
asyncInflightTimeout :: Int
asyncInflightTimeout = 5_000_000

-- | Block (bounded by 'asyncInflightTimeout') until no 'tcAsync = Real' spawned
-- async worker is still running.
-- POST-CONTRACT: Returns once 'asyncInflight' reads 0, or the timeout fires
-- (best-effort; mirrors the @tgTest@ quiescence safety net).
waitForAsyncInflight :: Mocks serviceLib -> IO ()
waitForAsyncInflight testMocks = do
    delay <- registerDelay asyncInflightTimeout
    atomically $ do
        expired <- readTVar delay
        n <- readTVar (asyncInflight testMocks)
        unless (expired || n == 0) retry

-- | Shared engine for running a test interpreter with explicit config.
-- PRE-CONTRACT: The supplied DefaultApp and Mocks are compatible (same serviceLib).
-- POST-CONTRACT: Queued logs are drained into mock refs before returning; exceptions re-throw with original stack.
runWithConfigEngine :: App.DefaultApp serviceLib -> TestConfig -> Mocks serviceLib -> TestInterpreter serviceLib a -> IO a
runWithConfigEngine app cfg testMocks action = do
    let env = EnvWithMocks{mocks = testMocks, defaultApp = app, testConfig = cfg}
    result <- tryAny $ runRIO env $ runTestInterpreter action
    -- Await 'tcAsync = Real' spawned workers (bounded) before draining logs so
    -- their side effects and log emissions settle into capture buffers. In Mocked
    -- mode the counter stays 0 and this returns immediately.
    waitForAsyncInflight testMocks
    drainQueuedLogs env
    either throwIO pure result

-- | Run a test action from plain 'IO' using a caller-supplied application and mock set.
-- Uses 'defaultTestConfig' (all-mocked) for backward compatibility.
-- POST-CONTRACT: Queued logs are drained into mock refs before returning; exceptions re-throw with original stack.
runWithMocks :: App.DefaultApp serviceLib -> Mocks serviceLib -> TestInterpreter serviceLib a -> IO a
runWithMocks app = runWithConfigEngine app defaultTestConfig

-- | Run a test action inside 'RIO DefaultApp' after allocating a fresh mock set.
-- POST-CONTRACT: The returned mocks reflect all side effects captured during the action.
runInsideWithDefaultMocks :: TestInterpreter serviceLib a -> RIO (App.DefaultApp serviceLib) (Mocks serviceLib, a)
runInsideWithDefaultMocks action = do
    testMocks <- liftIO makeMocks
    result <- runInsideWithMocks testMocks action
    pure (testMocks, result)

-- | Run a test action from plain 'IO' after allocating a fresh mock set.
-- POST-CONTRACT: The returned mocks reflect all side effects captured during the action.
runWithDefaultMocks :: App.DefaultApp serviceLib -> TestInterpreter serviceLib a -> IO (Mocks serviceLib, a)
runWithDefaultMocks app action = do
    testMocks <- makeMocks
    result <- runWithMocks app testMocks action
    pure (testMocks, result)

-- | Run a test action from plain IO with an explicit 'TestConfig' and caller-supplied mocks.
-- POST-CONTRACT: Queued logs are drained into mock refs before returning; exceptions re-throw with original stack.
runWithConfig :: App.DefaultApp serviceLib -> TestConfig -> Mocks serviceLib -> TestInterpreter serviceLib a -> IO a
runWithConfig app cfg = runWithConfigEngine app cfg

-- | Run a test action from plain IO with an explicit 'TestConfig' after allocating a fresh mock set.
-- POST-CONTRACT: The returned mocks reflect all side effects captured during the action.
runWithDefaultConfig :: App.DefaultApp serviceLib -> TestConfig -> TestInterpreter serviceLib a -> IO (Mocks serviceLib, a)
runWithDefaultConfig app cfg action = do
    testMocks <- makeMocks
    result <- runWithConfig app cfg testMocks action
    pure (testMocks, result)

-- | Run a test action inside RIO DefaultApp with explicit config and caller-supplied mocks.
runInsideWithConfig :: TestConfig -> Mocks serviceLib -> TestInterpreter serviceLib a -> RIO (App.DefaultApp serviceLib) a
runInsideWithConfig cfg testMocks action = do
    app <- ask
    liftIO $ runWithConfig app cfg testMocks action

-- | Run a test action inside RIO DefaultApp with explicit config after allocating fresh mocks.
-- POST-CONTRACT: The returned mocks reflect all side effects captured during the action.
runInsideWithDefaultConfig :: TestConfig -> TestInterpreter serviceLib a -> RIO (App.DefaultApp serviceLib) (Mocks serviceLib, a)
runInsideWithDefaultConfig cfg action = do
    testMocks <- liftIO makeMocks
    result <- runInsideWithConfig cfg testMocks action
    pure (testMocks, result)

-- | Allocate a fresh mock set seeded with canned AI chat-completion responses.
-- POST-CONTRACT: The returned 'Mocks' has the given responses queued FIFO in its 'aiMock'.
makeMocksWithAi :: [Chat.ChatCompletionObject] -> IO (Mocks serviceLib)
makeMocksWithAi responses = do
    base <- makeMocks
    aiM <- createAiMock responses
    pure base{aiMock = aiM}

-- | Run a test action from plain 'IO' with a caller-supplied application and a fresh mock set seeded with canned AI responses.
-- POST-CONTRACT: The returned mocks reflect all side effects captured during the action, including AI requests.
runWithAiMocks :: App.DefaultApp serviceLib -> [Chat.ChatCompletionObject] -> TestInterpreter serviceLib a -> IO (Mocks serviceLib, a)
runWithAiMocks app responses action = do
    testMocks <- makeMocksWithAi responses
    result <- runWithMocks app testMocks action
    pure (testMocks, result)

-- | Run a test action inside 'RIO DefaultApp' after allocating a fresh mock set seeded with canned AI responses.
-- POST-CONTRACT: The returned mocks reflect all side effects captured during the action, including AI requests.
runInsideWithAiMocks :: [Chat.ChatCompletionObject] -> TestInterpreter serviceLib a -> RIO (App.DefaultApp serviceLib) (Mocks serviceLib, a)
runInsideWithAiMocks responses action = do
    testMocks <- liftIO $ makeMocksWithAi responses
    result <- runInsideWithMocks testMocks action
    pure (testMocks, result)

-- | Drop the collected mocks from a combined result returned inside 'RIO DefaultApp'.
discardMocks :: RIO (App.DefaultApp serviceLib) (Mocks serviceLib, a) -> RIO (App.DefaultApp serviceLib) a
discardMocks action = snd <$> action

-- | Read captured immediate Telegram send requests in call order.
-- POST-CONTRACT: Result is ordered earliest-first (call order).
readTgRequests :: Mocks serviceLib -> IO [WithImportance SendMessageRequest]
readTgRequests testMocks = reverse <$> readSomeRef (sendMessageRequests $ tgMock testMocks)

-- | Read captured scheduled Telegram requests in call order.
-- POST-CONTRACT: Result is ordered earliest-first (call order).
readScheduledTgRequests :: Mocks serviceLib -> IO [SendMessageRequest]
readScheduledTgRequests testMocks = reverse <$> readSomeRef (scheduledMessageRequests $ tgMock testMocks)

-- | Drain and return every 'OutgoingMessage' currently in the mailbox, earliest-first.
--
-- This is a /destructive/ snapshot: drained messages are removed from the
-- 'outgoingMailbox' 'TBQueue'. The @tgTest@ DSL relies on blocking @waitFor*@
-- reads (which consume as they match) rather than on this helper; it is provided
-- for ad-hoc inspection and for the runner's final mailbox snapshot.
-- POST-CONTRACT: The mailbox is left empty; result is ordered earliest-first.
readOutgoingMailbox :: Mocks serviceLib -> IO [OutgoingMessage]
readOutgoingMailbox testMocks = atomically $ drainQueue []
  where
    queue = outgoingMailbox (tgMock testMocks)
    -- | Accumulate available messages preserving FIFO order.
    drainQueue acc = do
        next <- tryReadTBQueue queue
        case next of
            Nothing -> pure (reverse acc)
            Just msg -> drainQueue (msg : acc)

-- | Read captured log payloads in emission order.
-- POST-CONTRACT: Result is ordered earliest-first (emission order).
readLog :: Mocks serviceLib -> IO [AppLogMsg]
readLog testMocks = reverse <$> readSomeRef (appLog testMocks)

-- | Read captured log payloads with their context and call site in emission order.
-- POST-CONTRACT: Result is ordered earliest-first (emission order).
readLogWithContext :: Mocks serviceLib -> IO [AppLogMsgWithContext]
readLogWithContext testMocks = reverse <$> readSomeRef (appLogWithContext testMocks)

-- | Read captured outgoing mails in send order.
-- POST-CONTRACT: Result is ordered earliest-first (send order).
readSentMails :: Mocks serviceLib -> IO [Mail]
readSentMails testMocks = reverse <$> readSomeRef (sentMails $ mailMock testMocks)

-- | Read captured AI chat-completion requests in call order.
-- POST-CONTRACT: Result is ordered earliest-first (call order).
readAiRequests :: Mocks serviceLib -> IO [Chat.CreateChatCompletion]
readAiRequests testMocks = reverse <$> readSomeRef (aiRequests $ aiMock testMocks)

-- | Read captured async scenarios in request order.
-- POST-CONTRACT: Result is ordered earliest-first (request order).
readScheduledScenarios :: Mocks serviceLib -> IO [ScenarioProgram Script serviceLib ()]
readScheduledScenarios testMocks = reverse <$> readSomeRef (scheduledScenarios testMocks)

-- | Build a mail value using the SMTP credentials from the current test environment.
buildMail :: Address -> Text -> Text -> TestInterpreter serviceLib Mail
buildMail recipient subject body = do
    creds <- view App.mailCredsL
    pure $ Mail.makeMail' creds recipient subject body

-- | Select the same database connection pool that production script dispatch would choose for the given mode.
selectDbPool :: DbMode -> EnvWithMocks serviceLib -> Pool Simple.Connection
selectDbPool ReadWrite env = App.pgDbPool $ defaultApp env
selectDbPool ReadOnly env = fromMaybe primary maybeReadOnly
  where
    -- | The wrapped application environment.
    app = defaultApp env
    -- | The primary read-write pool used as fallback.
    primary = App.pgDbPool app
    -- | The optional read-only pool, if configured.
    maybeReadOnly = App.pgDbPoolReadOnly app

-- | Append immediate Telegram requests to the mock log while preserving external read order.
logTgRequests :: [WithImportance SendMessageRequest] -> TestPerformer (AppWithBotEnv (EnvWithMocks serviceLib)) ()
logTgRequests requests = do
    telegramMock <- asks (tgMock . mocks . app)
    modifySomeRef (sendMessageRequests telegramMock) (reverse requests <>)

-- | Append scheduled Telegram requests to the mock log while preserving external read order.
logScheduledTgRequests :: [SendMessageRequest] -> TestPerformer (AppWithBotEnv (EnvWithMocks serviceLib)) ()
logScheduledTgRequests requests = do
    telegramMock <- asks (tgMock . mocks . app)
    modifySomeRef (scheduledMessageRequests telegramMock) (reverse requests <>)

-- | Append one outgoing mail to the mock log.
logMailSend :: Mail -> TestInterpreter serviceLib ()
logMailSend mail = do
    mockMail <- asks (mailMock . mocks)
    modifySomeRef (sentMails mockMail) (mail :)

-- | Return the next queued Telegram response or fall back to the default response.
dequeueTgResponse :: WithImportance SendMessageRequest -> TestPerformer (AppWithBotEnv (EnvWithMocks serviceLib)) (Response Message)
dequeueTgResponse request = do
    telegramMock <- asks (tgMock . mocks . app)
    queuedResponses <- readSomeRef $ sendMessageResponses telegramMock
    case queuedResponses of
        nextResponse : rest -> do
            modifySomeRef (sendMessageResponses telegramMock) (const rest)
            pure $ nextResponse request
        [] -> pure $ defaultResponse telegramMock

-- | A canned 'Chat.ChatCompletionObject' with no choices, used as the fallback
-- when the mock response queue is empty. Yields 'Nothing' in production code
-- paths that read @choices !? 0@.
emptyCompletion :: Chat.ChatCompletionObject
emptyCompletion =
    Chat.ChatCompletionObject
        { Chat.id = "empty"
        , Chat.choices = V.empty
        , Chat.created = 0
        , Chat.model = "empty"
        , Chat.reasoning_effort = Nothing
        , Chat.service_tier = Nothing
        , Chat.system_fingerprint = Nothing
        , Chat.object = "chat.completion"
        , Chat.usage = Usage 0 0 0 Nothing Nothing
        }

-- | Capture one rendered AI request by prepending it to the request log.
captureAiRequest :: AiMock -> Chat.CreateChatCompletion -> IO ()
captureAiRequest aiM req = modifySomeRef (aiRequests aiM) (req :)

-- | Return the next queued AI completion, or 'emptyCompletion' when the queue is drained.
-- POST-CONTRACT: The returned value is the head of the response queue, and the queue advances by one; never blocks.
dequeueAiCompletion :: AiMock -> IO Chat.ChatCompletionObject
dequeueAiCompletion aiM = do
    queuedResponses <- readSomeRef (aiResponses aiM)
    case queuedResponses of
        nextResponse : rest -> do
            modifySomeRef (aiResponses aiM) (const rest)
            pure nextResponse
        [] -> pure emptyCompletion

-- | Override the 'V1.createChatCompletion' method of a base 'V1.Methods' handle so
-- that each call captures the rendered request and returns the next queued mock
-- completion. Other methods are left untouched.
buildMockAiMethods :: V1.Methods -> AiMock -> V1.Methods
buildMockAiMethods base aiM =
    base
        { V1.createChatCompletion = \req ->
            captureAiRequest aiM req >> dequeueAiCompletion aiM
        }

-- | Unwrap the 'SendMessageRequest' carried by a 'WithImportance' marker.
importancePayload :: WithImportance SendMessageRequest -> SendMessageRequest
importancePayload (Regular req) = req
importancePayload (Important req) = req

-- | Extract the numeric 'ChatId' from a 'SomeChatId' when it targets a chat (not a @username).
someChatIdToChatId :: SomeChatId -> Maybe ChatId
someChatIdToChatId (SomeChatId chatId) = Just chatId
someChatIdToChatId (SomeChatUsername _) = Nothing

-- | Extract the raw text of a 'FileId'; doubles as the mock download-store key.
fileIdText :: FileId -> Text
fileIdText (FileId txt) = txt

{- | Serve mocked @getFile@ metadata from the mock's canned download store.

The canned bytes staged for the requested 'FileId' are turned into a 'File'
whose reported size is the ACTUAL canned byte length (so gate-A size checks in
'downloadCheckedFile' behave truthfully) and whose path points at the mock
store (@mock-files\/\<file_id\>@). A missing key fails loudly and
deterministically with the requested 'FileId' in the message: a test that
triggers @getFile@ for an unstaged file has wired its expectations wrong.
POST-CONTRACT: The returned response always carries @responseOk = True@ and
@fileFileSize == Just (length of the canned bytes)@.
-}
getFileMock :: FileId -> TestPerformer (AppWithBotEnv (EnvWithMocks serviceLib)) (Response File)
getFileMock fid = do
    tg <- askTgMock
    downloads <- readSomeRef (downloadableFiles tg)
    case HM.lookup (fileIdText fid) downloads of
        Just bytes ->
            pure $
                TGDefault.defaultResponse Nothing $
                    File
                        { fileFileId = fid
                        , fileFileUniqueId = fid
                        , fileFileSize = Just (fromIntegral (BS.length bytes))
                        , fileFilePath = Just ("mock-files/" <> fileIdText fid)
                        }
        Nothing ->
            throwString $
                "LazyCircus.Testing.Performer.getFileMock: no canned download staged for " <> show fid

-- | Record an async scenario request without executing it ('tcAsync = Mocked').
captureAsyncScenario :: ScenarioProgram Script serviceLib () -> TestInterpreter serviceLib ()
captureAsyncScenario action = do
    asyncLog <- asks (scheduledScenarios . mocks)
    modifySomeRef asyncLog (action :)

-- | Dispatch a 'LazyCircus.Scenario.runAsync' control program according to 'tcAsync'.
-- 'Mocked' captures the scenario (no execution); 'Real' spawns it on a background
-- thread so its side effects genuinely run and land in the usual capture buffers.
runAsyncTest ::
    ScenarioProgram Script serviceLib () ->
    TestInterpreter serviceLib ()
runAsyncTest action = do
    mode <- asks (tcAsync . testConfig)
    case mode of
        Mocked -> captureAsyncScenario action
        Real -> spawnAsyncScenario action

-- | Spawn an async control program on a background thread ('tcAsync = Real').
--
-- The worker runs the scenario through the same test interpreter (same mocks,
-- mailbox, and DB connection), so a @sendMessage@ inside it publishes an
-- 'OutgoingMessage' to the shared 'outgoingMailbox' that @waitFor*@ observes
-- exactly like a synchronous reply. The 'asyncInflight' counter is incremented
-- synchronously (before the spawn returns) and decremented when the worker
-- finishes, so 'runWithConfigEngine' can await all spawned workers before
-- returning, which in @tgTest@ transitively gates 'waitForQuiescent' (a per-update
-- action does not return until its spawned workers finish).
--
-- Worker exceptions are caught and logged via 'sublangLog' (mirroring production
-- 'runAsyncWorker'); they never crash the test harness. A failed worker yields no
-- reply, so @waitFor*@ then fails with 'TgTestTimeout' — disambiguate via 'readLog'.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: 'asyncInflight' is incremented synchronously (before this
-- returns) and decremented once the worker finishes (or throws).
spawnAsyncScenario :: HasCallStack => ScenarioProgram Script serviceLib () -> TestInterpreter serviceLib ()
spawnAsyncScenario action = do
    counter <- asks (asyncInflight . mocks)
    -- Increment BEFORE spawning so 'waitForAsyncInflight' cannot observe a false
    -- zero between this function returning and the worker thread starting.
    atomically $ modifyTVar' counter (+ 1)
    let dec = atomically $ modifyTVar' counter (subtract 1)
        runWorker = do
            result <- tryAny (run action)
            case result of
                Left e ->
                    sublangLog callStack "Scenario" (ErrorLogMsg ("Async worker action failed: " <> tshow e))
                Right _ -> pure ()
    void $ async $ finally runWorker dec

-- | Drain queued contextual logs into the mock refs while preserving emission order.
drainQueuedLogs :: EnvWithMocks serviceLib -> IO ()
drainQueuedLogs env = do
    queuedLogs <- atomically $ readAllQueuedLogs []
    let testMocks = mocks env
        plainLogs = map logMsg queuedLogs
    modifySomeRef (appLog testMocks) (reverse plainLogs <>)
    modifySomeRef (appLogWithContext testMocks) (reverse queuedLogs <>)
  where
    queue = mockLogQueue (mocks env)

    -- | Drain all pending messages from the TQueue into a list, preserving order.
    readAllQueuedLogs acc = do
        next <- tryReadTQueue queue
        case next of
            Nothing -> pure $ reverse acc
            Just msg -> readAllQueuedLogs (msg : acc)
