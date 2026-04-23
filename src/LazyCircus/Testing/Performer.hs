{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Mock-backed interpreter utilities for tests that run current LazyCircus scripts.
module LazyCircus.Testing.Performer (
    OnSendMessageRequest,
    TgMock (..),
    MailMock (..),
    Mocks (..),
    EnvWithMocks (..),
    TestInterpreter (..),
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
    readLog,
    readLogWithContext,
    readSentMails,
    readScheduledScenarios,
)
where

import Control.Monad.Free.Church (iterM)
import Database.PostgreSQL.Simple qualified as Simple
import LazyCircus.App.Default qualified as App
import LazyCircus.App.Log
import LazyCircus.App.Service (HasServiceLib (..), callViaServiceLib)
import LazyCircus.DB.Types (PgDB)
import LazyCircus.DB.WithConnection (AppWithConnection (..))
import LazyCircus.Mail qualified as Mail
import LazyCircus.Scenario (DbMode (..), Scenario (..), ScenarioProgram)
import LazyCircus.Scene.AI.Lang (AILangF (..), AIScript)
import LazyCircus.Scene.DB.Class (DBScriptPerformer (..), DbError (..))
import LazyCircus.Scene.DB.Lang (DBLangF (..), DBScript)
import LazyCircus.Scene.DB.RLS (RLSContext, setRLSContext)
import LazyCircus.Scene.Log (LogLangF (..))
import LazyCircus.Scene.Mail.Lang (MailLangF (..), MailScript)
import LazyCircus.Scene.Telegram.Lang (TelegramScript, TelegramScriptF (..))
import LazyCircus.Script (Script (..))
import LazyCircus.Telegram.Default qualified as TGDefault
import LazyCircus.Telegram.Types (WithImportance (..))
import Network.Mail.Mime (Address, Mail)
import RIO
import RIO.Time (getCurrentTime)
import Telegram.Bot.API (Message, Response, SendMessageRequest)
import Telegram.Bot.API.Types (File, FileId)

-- | Response factory used by the Telegram mock to derive a reply from one outgoing request.
type OnSendMessageRequest = WithImportance SendMessageRequest -> Response Message

-- | Telegram mock state used by the test interpreter.
data TgMock = TgMock
    { sendMessageResponses :: SomeRef [OnSendMessageRequest]
    -- ^ queued canned responses consumed by 'sendMessage'
    , sendMessageRequests :: SomeRef [WithImportance SendMessageRequest]
    -- ^ captured outgoing immediate Telegram sends
    , scheduledMessageRequests :: SomeRef [SendMessageRequest]
    -- ^ captured deferred Telegram sends requested via 'scheduleMessages'
    , defaultResponse :: Response Message
    -- ^ fallback response used when no canned response is queued
    }

-- | Mail mock state used by the test interpreter.
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

-- | Delegates service library access to the wrapped DefaultApp.
instance HasServiceLib (EnvWithMocks serviceLib) serviceLib where
    serviceLibL = lens defaultApp (\env x -> env{defaultApp = x}) . serviceLibL

-- | Interpreter monad used by test helpers and mock-backed runners.
newtype TestInterpreter serviceLib a = TestInterpreter
    { runTestInterpreter :: RIO (EnvWithMocks serviceLib) a
    }
    deriving
        ( Applicative
        , Functor
        , Monad
        , MonadIO
        , MonadReader (EnvWithMocks serviceLib)
        , MonadUnliftIO
        )

-- | Re-target a test action to an updated environment.
changeEnv :: (EnvWithMocks serviceLib -> EnvWithMocks serviceLib) -> TestInterpreter serviceLib a -> TestInterpreter serviceLib a
changeEnv f (TestInterpreter action) = TestInterpreter (mapRIO f action)

-- | Run one top-level 'Script' using the mock-backed test interpreter.
runScript :: Script a -> TestInterpreter serviceLib a
runScript (TelegramScriptDef botName script) = runTelegramWithMockLogging botName script
runScript (MailScriptDef script) = runMailWithMockLogging script
runScript (AIScriptDef script) = runAIWithMockLogging script
runScript (DBScriptDef db mode script) = runDBWithMockLogging db mode script

-- | Run a 'ScenarioProgram' using current mock semantics for logging, AI, and async work.
runScenarioProgram :: ScenarioProgram Script serviceLib a -> TestInterpreter serviceLib a
runScenarioProgram = iterM go
  where
    go (EvalScript script next) = do
        result <- runScript script
        next result
    go (GetDateTime next) = do
        now <- liftIO getCurrentTime
        next now
    go (Throw err next) = do
        result <- throwIO err
        next result
    go (RunSafely action next) = do
        result <- try $ runScenarioProgram action
        next result
    go (ScenarioLogMsg cs msg next) = do
        captureLogMessage "Scenario" cs msg
        next
    go (ScenarioWithLogCtx values action next) = do
        result <- withExtendedLogContext values $ runScenarioProgram action
        next result
    go (GetExtraContext next) = do
        ctx <- asks (App.extraContext . defaultApp)
        next ctx
    go (RunAsync action next) = do
        captureAsyncScenario action
        next
    go (CallService req next) = do
        res <- callViaServiceLib req
        next res

-- | Run a DB script while capturing its embedded logs into mocks instead of the shared log queue.
runDBWithMockLogging :: PgDB db -> DbMode -> DBScript db a -> TestInterpreter serviceLib a
runDBWithMockLogging db mode = iterM go
  where
    go (Create tables next) = do
        ensureReadWrite mode
        result <- runDbAction mode $ create' db mode tables
        next result
    go (CreateAsIs tables next) = do
        ensureReadWrite mode
        result <- runDbAction mode $ createAsIs' db mode tables
        next result
    go (Find lid next) = do
        result <- runDbAction mode $ find' db mode lid
        next result
    go (Update table lid next) = do
        ensureReadWrite mode
        result <- runDbAction mode $ update' db mode table lid
        next result
    go (UpdateMany table lids next) = do
        ensureReadWrite mode
        result <- runDbAction mode $ updateMany' db mode table lids
        next result
    go (Delete lid next) = do
        ensureReadWrite mode
        runDbAction mode $ delete' db mode lid
        next
    go (RunQuery query next) = do
        result <- runDbAction mode $ runQuery' db mode query
        next result
    go (RawQuery query params next) = do
        result <- runDbAction mode $ rawQuery' mode query params
        next result
    go (WithTransaction mCtx nested next) = do
        result <- runDbTransaction mode mCtx $ runDBWithMockLogging db mode nested
        next result
    go (DBLog logAction next) =
        runLogWithMockCapture "DB" (runDBWithMockLogging db mode) (fmap next logAction)

-- | Run a Telegram script while capturing sends, schedules, and logs into mocks.
runTelegramWithMockLogging :: Text -> TelegramScript a -> TestInterpreter serviceLib a
runTelegramWithMockLogging botName = iterM go
  where
    go (GetFile fileId next) = do
        result <- getFileMock fileId
        next result
    go (GetBotName next) = next botName
    go (SendMessage request next) = do
        logTgRequests [request]
        response <- dequeueTgResponse request
        next response
    go (ScheduleMessages requests next) = do
        logScheduledTgRequests requests
        next
    go (SetBotCommands _commands next) = next
    go (SetMessageReaction _request next) = next
    go (AnswerCallbackQuery _request next) = next
    go (EditMessageText _request next) = next Nothing
    go (TgLog logAction next) =
        runLogWithMockCapture "Telegram" (runTelegramWithMockLogging botName) (fmap next logAction)

-- | Build a Telegram mock with a fallback response and optional queued send responses.
createTgMock :: Response Message -> Maybe [OnSendMessageRequest] -> IO TgMock
createTgMock fallback queuedResponses = do
    responseQueue <- newSomeRef $ fromMaybe [] queuedResponses
    requestLog <- newSomeRef []
    scheduledLog <- newSomeRef []
    pure
        TgMock
            { sendMessageResponses = responseQueue
            , sendMessageRequests = requestLog
            , scheduledMessageRequests = scheduledLog
            , defaultResponse = fallback
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
    mockMail <- createSimpleMailMock
    asyncLog <- newSomeRef []
    pure
        Mocks
            { tgMock = telegramMock
            , appLog = logMessages
            , appLogWithContext = contextualLogMessages
            , mailMock = mockMail
            , scheduledScenarios = asyncLog
            }

-- | Run a test action inside 'RIO DefaultApp' using a caller-supplied mock set.
runInsideWithMocks :: Mocks serviceLib -> TestInterpreter serviceLib a -> RIO (App.DefaultApp serviceLib) a
runInsideWithMocks testMocks action = mapRIO (EnvWithMocks testMocks) $ runTestInterpreter action

-- | Run a test action from plain 'IO' using a caller-supplied application and mock set.
runWithMocks :: App.DefaultApp serviceLib -> Mocks serviceLib -> TestInterpreter serviceLib a -> IO a
runWithMocks app testMocks action = runRIO env $ runTestInterpreter action
  where
    env = EnvWithMocks{mocks = testMocks, defaultApp = app}

-- | Run a test action inside 'RIO DefaultApp' after allocating a fresh mock set.
runInsideWithDefaultMocks :: TestInterpreter serviceLib a -> RIO (App.DefaultApp serviceLib) (Mocks serviceLib, a)
runInsideWithDefaultMocks action = do
    testMocks <- liftIO makeMocks
    result <- runInsideWithMocks testMocks action
    pure (testMocks, result)

-- | Run a test action from plain 'IO' after allocating a fresh mock set.
runWithDefaultMocks :: App.DefaultApp serviceLib -> TestInterpreter serviceLib a -> IO (Mocks serviceLib, a)
runWithDefaultMocks app action = do
    testMocks <- makeMocks
    result <- runWithMocks app testMocks action
    pure (testMocks, result)

-- | Drop the collected mocks from a combined result returned inside 'RIO DefaultApp'.
discardMocks :: RIO (App.DefaultApp serviceLib) (Mocks serviceLib, a) -> RIO (App.DefaultApp serviceLib) a
discardMocks action = snd <$> action

-- | Read captured immediate Telegram send requests in call order.
readTgRequests :: Mocks serviceLib -> IO [WithImportance SendMessageRequest]
readTgRequests testMocks = reverse <$> readSomeRef (sendMessageRequests $ tgMock testMocks)

-- | Read captured scheduled Telegram requests in call order.
readScheduledTgRequests :: Mocks serviceLib -> IO [SendMessageRequest]
readScheduledTgRequests testMocks = reverse <$> readSomeRef (scheduledMessageRequests $ tgMock testMocks)

-- | Read captured log payloads in emission order.
readLog :: Mocks serviceLib -> IO [AppLogMsg]
readLog testMocks = reverse <$> readSomeRef (appLog testMocks)

-- | Read captured log payloads with their context and call site in emission order.
readLogWithContext :: Mocks serviceLib -> IO [AppLogMsgWithContext]
readLogWithContext testMocks = reverse <$> readSomeRef (appLogWithContext testMocks)

-- | Read captured outgoing mails in send order.
readSentMails :: Mocks serviceLib -> IO [Mail]
readSentMails testMocks = reverse <$> readSomeRef (sentMails $ mailMock testMocks)

-- | Read captured async scenarios in request order.
readScheduledScenarios :: Mocks serviceLib -> IO [ScenarioProgram Script serviceLib ()]
readScheduledScenarios testMocks = reverse <$> readSomeRef (scheduledScenarios testMocks)

-- | Run a mail script while capturing sends and logs into mocks.
runMailWithMockLogging :: MailScript a -> TestInterpreter serviceLib a
runMailWithMockLogging = iterM go
  where
    go (SendMail mail next) = do
        logMailSend mail
        next
    go (MakeMail recipient subject body next) = do
        mail <- buildMail recipient subject body
        next mail
    go (MailLog logAction next) =
        runLogWithMockCapture "Mail" runMailWithMockLogging (fmap next logAction)

-- | Run an AI script while returning no decoded answers and capturing logs into mocks.
runAIWithMockLogging :: AIScript a -> TestInterpreter serviceLib a
runAIWithMockLogging = iterM go
  where
    go (Ask _request next) = next Nothing
    go (AILog logAction next) =
        runLogWithMockCapture "AI" runAIWithMockLogging (fmap next logAction)

-- | Capture one logging instruction for any sub-language and preserve nested log context.
runLogWithMockCapture ::
    Text ->
    (forall x. prog x -> TestInterpreter serviceLib x) ->
    LogLangF prog (TestInterpreter serviceLib a) ->
    TestInterpreter serviceLib a
runLogWithMockCapture langTag runProg = \case
    LogMsg cs msg next -> do
        captureLogMessage langTag cs msg
        next
    WithLogCtx values program next -> do
        result <- withExtendedLogContext values $ runProg program
        next result

-- | Build a mail value using the SMTP credentials from the current test environment.
buildMail :: Address -> Text -> Text -> TestInterpreter serviceLib Mail
buildMail recipient subject body = do
    creds <- asks (App.mailCreds . defaultApp)
    pure $ Mail.makeMail' creds recipient subject body

-- | Reject writes when the DB script is running in read-only mode.
ensureReadWrite :: DbMode -> TestInterpreter serviceLib ()
ensureReadWrite ReadWrite = pure ()
ensureReadWrite ReadOnly = throwIO DbReadOnlyViolation

-- | Run one database action against the connection selected by the current DB mode.
runDbAction :: DbMode -> RIO (AppWithConnection (App.DefaultApp serviceLib)) a -> TestInterpreter serviceLib a
runDbAction mode action = do
    env <- ask
    let connection = selectDbConnection mode env
        dbEnv = AppWithConnection connection (defaultApp env)
    liftIO $ runRIO dbEnv action

-- | Run one transactional database action using the selected connection and current test environment.
runDbTransaction :: DbMode -> Maybe RLSContext -> TestInterpreter serviceLib a -> TestInterpreter serviceLib a
runDbTransaction mode mCtx action = do
    env <- ask
    let connection = selectDbConnection mode env
    liftIO $ Simple.withTransaction connection $ do
        setRLSContext connection mCtx
        runRIO env $ runTestInterpreter action

-- | Select the same database connection that production script dispatch would choose for the given mode.
selectDbConnection :: DbMode -> EnvWithMocks serviceLib -> Simple.Connection
selectDbConnection ReadWrite env = App.pgDbConnection $ defaultApp env
selectDbConnection ReadOnly env = fromMaybe primary maybeReadOnly
  where
    app = defaultApp env
    primary = App.pgDbConnection app
    maybeReadOnly = App.pgDbConnectionReadOnly app

-- | Capture one application log message together with the current logging context and language tag.
captureLogMessage :: Text -> CallStack -> AppLogMsg -> TestInterpreter serviceLib ()
captureLogMessage langTag cs msg = do
    env <- ask
    let
        testMocks = mocks env
        loggingContext = putInLoggingContext (App.logContext $ defaultApp env) [("lang", langTag)]
        contextualMsg = AppLogMsgWithContext msg loggingContext (extractCallSite cs)
    modifySomeRef (appLog testMocks) (msg :)
    modifySomeRef (appLogWithContext testMocks) (contextualMsg :)

-- | Run a test action with additional logging context entries layered on top of the current context.
withExtendedLogContext :: [(Text, Text)] -> TestInterpreter serviceLib a -> TestInterpreter serviceLib a
withExtendedLogContext values = changeEnv updateEnv
  where
    updateEnv env = env{defaultApp = app{App.logContext = updatedContext}}
      where
        app = defaultApp env
        updatedContext = putInLoggingContext (App.logContext app) values

-- | Append immediate Telegram requests to the mock log while preserving external read order.
logTgRequests :: [WithImportance SendMessageRequest] -> TestInterpreter serviceLib ()
logTgRequests requests = do
    telegramMock <- asks (tgMock . mocks)
    modifySomeRef (sendMessageRequests telegramMock) (reverse requests <>)

-- | Append scheduled Telegram requests to the mock log while preserving external read order.
logScheduledTgRequests :: [SendMessageRequest] -> TestInterpreter serviceLib ()
logScheduledTgRequests requests = do
    telegramMock <- asks (tgMock . mocks)
    modifySomeRef (scheduledMessageRequests telegramMock) (reverse requests <>)

-- | Append one outgoing mail to the mock log.
logMailSend :: Mail -> TestInterpreter serviceLib ()
logMailSend mail = do
    mockMail <- asks (mailMock . mocks)
    modifySomeRef (sentMails mockMail) (mail :)

-- | Return the next queued Telegram response or fall back to the default response.
dequeueTgResponse :: WithImportance SendMessageRequest -> TestInterpreter serviceLib (Response Message)
dequeueTgResponse request = do
    telegramMock <- asks (tgMock . mocks)
    queuedResponses <- readSomeRef $ sendMessageResponses telegramMock
    case queuedResponses of
        nextResponse : rest -> do
            modifySomeRef (sendMessageResponses telegramMock) (const rest)
            pure $ nextResponse request
        [] -> pure $ defaultResponse telegramMock

-- | Fail fast when a test uses Telegram file loading without providing a dedicated mock path.
getFileMock :: FileId -> TestInterpreter serviceLib (Response File)
getFileMock _ = throwString "LazyCircus.Testing.Performer: getFile is not implemented for tests"

-- | Record an async scenario request without executing it.
captureAsyncScenario :: ScenarioProgram Script serviceLib () -> TestInterpreter serviceLib ()
captureAsyncScenario action = do
    asyncLog <- asks (scheduledScenarios . mocks)
    modifySomeRef asyncLog (action :)
