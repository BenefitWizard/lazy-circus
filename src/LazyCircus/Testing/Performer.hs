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
    Mocks (..),
    EnvWithMocks (..),
    TestInterpreter,
    OutgoingMessage (..),
    OutgoingKind (..),
    runTestInterpreter,
    changeEnv,
    runScript,
    runScenarioProgram,
    runDBWithMockLogging,
    runTelegramWithMockLogging,
    createTgMock,
    createSimpleTgMock,
    createSimpleMailMock,
    makeMocks,
    runInsideWithMocks,
    runWithMocks,
    runInsideWithDefaultMocks,
    runWithDefaultMocks,
    discardMocks,
    readTgRequests,
    readScheduledTgRequests,
    readOutgoingMailbox,
    readLog,
    readLogWithContext,
    readSentMails,
    readScheduledScenarios,
)
where

import Database.PostgreSQL.Simple qualified as Simple
import LazyCircus.AI (HasAIMethods (..), emptyConversation)
import LazyCircus.App.Default qualified as App
import LazyCircus.App.Log
import LazyCircus.App.Service (HasServiceLib (..), HasToolCallExec (..), HasToolDescriptions (..), callViaServiceLib)
import LazyCircus.AsyncWorker.Types (HasScheduledActions (..))
import LazyCircus.DB.Class (HasPgConnection (..), HasPgConnectionReadOnly (..))
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
import LazyCircus.Scene.AI.Class (AILangPerformer (..), runAI)
import LazyCircus.Scene.DB.Class (HasDbConnection (..), runDB)
import LazyCircus.Scene.DB.Lang (DBScript)
import LazyCircus.Scene.HTTP.Class (HTTPPerformer (..), runHTTP)
import LazyCircus.Scene.Mail.Class (MailScriptPerformer (..), runMail)
import LazyCircus.Scene.Telegram.Class (TelegramScriptPerformer (..), runTelegram)
import LazyCircus.Scene.Telegram.Lang (TelegramScript)
import LazyCircus.Script (Script (..))
import LazyCircus.Telegram qualified as TG
import LazyCircus.Telegram.Default qualified as TGDefault
import LazyCircus.Telegram.Types (AppWithBotEnv (..), WithImportance (..))
import Network.Mail.Mime (Address, Mail)
import RIO
import RIO.Map qualified as M
import RIO.Process (HasProcessContext (..))
import RIO.Time (getCurrentTime)
import Servant.Client (mkClientEnv, runClientM)
import Telegram.Bot.API (ChatId, Message, MessageId, Response, SendMessageRequest, SomeChatId (..), SomeReplyMarkup, editMessageTextChatId, editMessageTextMessageId, editMessageTextText, messageMessageId, responseResult, sendDocumentCaption, sendDocumentChatId, sendMessageChatId, sendMessageReplyMarkup, sendMessageText, setMessageReactionRequestChatId, setMessageReactionRequestMessageId)
import Telegram.Bot.API.Types (File, FileId, MessageId (..))

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
    deriving (Eq, Show)

-- | A captured outgoing Telegram side effect, observable by the @tgTest@ DSL.
--
-- The mock publishes one 'OutgoingMessage' to the 'outgoingMailbox' 'STM.TBQueue'
-- for every Telegram operation that produces user-visible traffic, so the test
-- DSL's @waitFor*@ operations can observe replies deterministically through STM.
-- The 'omMessageId' is the /assigned/ incremental id for @sendMessage@\/@sendDocument@
-- (see 'tgMockMessageIdCounter'), or the /target/ id for @setMessageReaction@\/@editMessageText@.
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
    , scheduledScenarios :: SomeRef [ScenarioProgram Script serviceLib ()]
    -- ^ captured async control programs requested through 'runAsync'
    }

-- | Test runtime environment that combines mocks with the real application environment.
data EnvWithMocks serviceLib = EnvWithMocks
    { mocks :: Mocks serviceLib
    -- ^ mutable capture state for the current test run
    , defaultApp :: App.DefaultApp serviceLib
    -- ^ real runtime dependencies used for DB access, config, and mail construction
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

-- | Delegates primary PostgreSQL access to the wrapped DefaultApp.
instance HasPgConnection (EnvWithMocks serviceLib) where
    postgresL = lens defaultApp (\env app -> env{defaultApp = app}) . postgresL

-- | Delegates read-only PostgreSQL access to the wrapped DefaultApp.
instance HasPgConnectionReadOnly (EnvWithMocks serviceLib) where
    postgresReadOnlyL = lens defaultApp (\env app -> env{defaultApp = app}) . postgresReadOnlyL

-- | Shares the primary PostgreSQL connection as the generic DB connection.
instance HasDbConnection (EnvWithMocks serviceLib) where
    dbConnectionL = lens defaultApp (\env app -> env{defaultApp = app}) . dbConnectionL

-- | Delegates legacy main-db access to the wrapped DefaultApp.
instance App.HasMainDb (EnvWithMocks serviceLib) where
    mainDbL = lens defaultApp (\env app -> env{defaultApp = app}) . App.mainDbL

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
instance TelegramScriptPerformer (TestPerformer (AppWithBotEnv (EnvWithMocks serviceLib))) where
    getFile' = getFileMock
    getBotName' = TG.getBotName
    sendMessage' request = do
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
    scheduleMessages' = logScheduledTgRequests
    setBotCommands' _ = pure ()
    setMessageReaction' req = do
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
    answerCallbackQuery' _ = pure ()
    editMessageText' req = do
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
    sendDocument' req = do
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
instance MailScriptPerformer (TestPerformer (EnvWithMocks serviceLib)) where
    sendMail' = logMailSend
    makeMail' = buildMail

-- | Returns no decoded AI answers in tests.
-- The continuing primitive is overridden so the stateless 'ask'' default (and
-- the 'solveWithAgentContinuing'' default) inherit the no-op behaviour.
instance AILangPerformer (TestPerformer (EnvWithMocks serviceLib)) where
    askContinuing' _ _ = pure (Nothing, emptyConversation)

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
    runAsync' = captureAsyncScenario
    callService' = callViaServiceLib
    withLogContext' values action =
        local (logContextL %~ (`putInLoggingContext` values)) (run action)

-- | Run one top-level 'Script' using the production-style test performer dispatch.
-- PRE-CONTRACT: The bot name in a 'TelegramScriptDef' must be configured in 'App.botEnvsL'.
runScript :: Script a -> TestInterpreter serviceLib a
runScript (TelegramScriptDef botName script) = runTelegramWithMockLogging botName script
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

-- | Run a DB script using the same connection-selection projection as production.
runDBWithMockLogging :: PgDB db -> DbMode -> DBScript db a -> TestInterpreter serviceLib a
runDBWithMockLogging db mode script = do
    conn <- asks (selectDbConnection mode)
    changeEnv (AppWithConnection conn) (runDB db mode script)

-- | Run a Telegram script using the same bot-environment projection as production.
-- PRE-CONTRACT: The bot name must be present in 'App.botEnvsL'; throws 'NoBotConfigured' otherwise.
runTelegramWithMockLogging :: Text -> TelegramScript a -> TestInterpreter serviceLib a
runTelegramWithMockLogging botName script = do
    botEnvs <- view App.botEnvsL
    case M.lookup botName botEnvs of
        Nothing -> throwIO $ Default.NoBotConfigured botName
        Just botEnv -> changeEnv (AppWithBotEnv botEnv) (runTelegram script)

-- | Bounded capacity of the outgoing-mailbox 'TBQueue'.
-- Sized generously relative to the number of replies a single bot turn can produce
-- so that a burst of sends never blocks the performer thread on a full queue.
outgoingMailboxSize :: Natural
outgoingMailboxSize = 64

-- | Build a Telegram mock with a fallback response and optional queued send responses.
-- POST-CONTRACT: The returned 'TgMock' has empty request logs; queued responses are consumed FIFO by 'sendMessage'.
createTgMock :: Response Message -> Maybe [OnSendMessageRequest] -> IO TgMock
createTgMock fallback queuedResponses = do
    responseQueue <- newSomeRef $ fromMaybe [] queuedResponses
    requestLog <- newSomeRef []
    scheduledLog <- newSomeRef []
    mailbox <- newTBQueueIO outgoingMailboxSize
    msgIdCounter <- newTVarIO 0
    pure
        TgMock
            { sendMessageResponses = responseQueue
            , sendMessageRequests = requestLog
            , scheduledMessageRequests = scheduledLog
            , defaultResponse = fallback
            , outgoingMailbox = mailbox
            , tgMockMessageIdCounter = msgIdCounter
            }

-- | Build a Telegram mock that always returns the standard canned message response.
createSimpleTgMock :: IO TgMock
createSimpleTgMock = createTgMock (TGDefault.defaultResponse Nothing TGDefault.defaultMessage) Nothing

-- | Build an empty mail mock with no captured sends.
createSimpleMailMock :: IO MailMock
createSimpleMailMock = do
    mailLog <- newSomeRef []
    pure MailMock{sentMails = mailLog}

-- | Allocate a fresh set of empty mocks for one test run.
makeMocks :: IO (Mocks serviceLib)
makeMocks = do
    telegramMock <- createSimpleTgMock
    logMessages <- newSomeRef []
    contextualLogMessages <- newSomeRef []
    logQueue <- newTQueueIO
    mockMail <- createSimpleMailMock
    asyncLog <- newSomeRef []
    pure
        Mocks
            { tgMock = telegramMock
            , appLog = logMessages
            , appLogWithContext = contextualLogMessages
            , mockLogQueue = logQueue
            , mailMock = mockMail
            , scheduledScenarios = asyncLog
            }

-- | Run a test action inside 'RIO DefaultApp' using a caller-supplied mock set.
runInsideWithMocks :: Mocks serviceLib -> TestInterpreter serviceLib a -> RIO (App.DefaultApp serviceLib) a
runInsideWithMocks testMocks action = do
    app <- ask
    liftIO $ runWithMocks app testMocks action

-- | Run a test action from plain 'IO' using a caller-supplied application and mock set.
-- POST-CONTRACT: Queued logs are drained into mock refs before returning; exceptions re-throw with original stack.
runWithMocks :: App.DefaultApp serviceLib -> Mocks serviceLib -> TestInterpreter serviceLib a -> IO a
runWithMocks app testMocks action = do
    let env = EnvWithMocks{mocks = testMocks, defaultApp = app}
    result <- tryAny $ runRIO env $ runTestInterpreter action
    drainQueuedLogs env
    either throwIO pure result

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

-- | Read captured async scenarios in request order.
-- POST-CONTRACT: Result is ordered earliest-first (request order).
readScheduledScenarios :: Mocks serviceLib -> IO [ScenarioProgram Script serviceLib ()]
readScheduledScenarios testMocks = reverse <$> readSomeRef (scheduledScenarios testMocks)

-- | Build a mail value using the SMTP credentials from the current test environment.
buildMail :: Address -> Text -> Text -> TestInterpreter serviceLib Mail
buildMail recipient subject body = do
    creds <- view App.mailCredsL
    pure $ Mail.makeMail' creds recipient subject body

-- | Select the same database connection that production script dispatch would choose for the given mode.
selectDbConnection :: DbMode -> EnvWithMocks serviceLib -> Simple.Connection
selectDbConnection ReadWrite env = App.pgDbConnection $ defaultApp env
selectDbConnection ReadOnly env = fromMaybe primary maybeReadOnly
  where
    -- | The wrapped application environment.
    app = defaultApp env
    -- | The primary read-write connection used as fallback.
    primary = App.pgDbConnection app
    -- | The optional read-only connection, if configured.
    maybeReadOnly = App.pgDbConnectionReadOnly app

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

-- | Unwrap the 'SendMessageRequest' carried by a 'WithImportance' marker.
importancePayload :: WithImportance SendMessageRequest -> SendMessageRequest
importancePayload (Regular req) = req
importancePayload (Important req) = req

-- | Extract the numeric 'ChatId' from a 'SomeChatId' when it targets a chat (not a @username).
someChatIdToChatId :: SomeChatId -> Maybe ChatId
someChatIdToChatId (SomeChatId chatId) = Just chatId
someChatIdToChatId (SomeChatUsername _) = Nothing

-- | Fail fast when a test uses Telegram file loading without providing a dedicated mock path.
getFileMock :: FileId -> TestPerformer (AppWithBotEnv (EnvWithMocks serviceLib)) (Response File)
getFileMock _ = throwString "LazyCircus.Testing.Performer: getFile is not implemented for tests"

-- | Record an async scenario request without executing it.
captureAsyncScenario :: ScenarioProgram Script serviceLib () -> TestInterpreter serviceLib ()
captureAsyncScenario action = do
    asyncLog <- asks (scheduledScenarios . mocks)
    modifySomeRef asyncLog (action :)

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
