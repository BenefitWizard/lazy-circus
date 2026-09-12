{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Constructs a DefaultApp runtime environment for the Lazy Circus demo application.
module DemoEnv (
    DemoConfig (..),
    defaultDemoConfig,
    readDemoConfig,
    withDemoApp,
    runDemoScenario,
    setupDatabase,
    testConnectionString,
) where

import RIO
import RIO.HashMap qualified as HM
import Text.Read (readMaybe)

import Control.Exception (AsyncException)
import Control.Exception qualified as CE

import Data.Pool (destroyAllResources)
import Database.PostgreSQL.Simple (Connection, Only (..), close, connectPostgreSQL, execute_, query_)
import Database.PostgreSQL.Simple.Types (Query (..))

import LazyCircus.App.Default hiding (cfgAiApiKey, cfgAiBaseUrl, DefaultAppConfig)
import LazyCircus.App.Default qualified as LAD (DefaultAppConfig (..))
import LazyCircus.App.Log hiding (genLogFunc, logContext, logFunc, logQueue)
import LazyCircus.AsyncWorker (runAsyncWorkerPool, runTimerService)
import LazyCircus.Performer.Default (runDefaultPerformer)
import LazyCircus.Scenario (ScenarioProgram, run)
import LazyCircus.Script (Script)

import Common (migration)
import LazyCircus.App.Service
import SimpleService (handleSimpleRequest, handleAddExpressionRequest)
import SimpleServiceLib (AllServices, AllServicesConfig (..), allToolDescriptions, mkAllServices, mkToolCallExec)
import System.Environment (lookupEnv)
import System.IO (putStrLn)

-- | Configuration values for the demo application, read from environment variables.
data DemoConfig = DemoConfig
    { cfgTgToken :: Maybe Text
    -- ^ Telegram bot token
    , cfgTgChatId :: Maybe Text
    -- ^ Telegram chat ID for notifications
    , cfgAiApiKey :: Maybe Text
    -- ^ AI service API key
    , cfgAiBaseUrl :: Maybe Text
    -- ^ AI service base URL
    , cfgSmtpHost :: String
    -- ^ SMTP server hostname
    , cfgSmtpPort :: Int
    -- ^ SMTP server port
    , cfgSmtpLogin :: String
    -- ^ SMTP login username
    , cfgSmtpPass :: String
    -- ^ SMTP login password
    , cfgSmtpName :: String
    -- ^ sender display name for outgoing emails
    , cfgSmtpUseTls :: Bool
    -- ^ whether to use STARTTLS for sending
    , cfgNotificationEmail :: Maybe String
    -- ^ email address for notifications
    , cfgAsyncWorkers :: Word
    -- ^ number of async workers draining the deferred-task queue; must be ≥ 1 in effect — 0 is clamped to 1 by runAsyncWorkerPool
    }

-- | Masks sensitive fields; tokens and passwords shown only as present/absent.
instance Show DemoConfig where
    show DemoConfig{..} =
        "DemoConfig { tgToken="
            <> show (isJust cfgTgToken)
            <> ", tgChatId="
            <> show cfgTgChatId
            <> ", aiApiKey="
            <> show (isJust cfgAiApiKey)
            <> ", aiBaseUrl="
            <> show cfgAiBaseUrl
            <> ", smtpHost="
            <> show cfgSmtpHost
            <> ", smtpPort="
            <> show cfgSmtpPort
            <> ", smtpLogin="
            <> show cfgSmtpLogin
            <> ", smtpPass="
            <> (if null cfgSmtpPass then "\"\"" else "\"***\"")
            <> ", smtpName="
            <> show cfgSmtpName
            <> ", smtpUseTls="
            <> show cfgSmtpUseTls
            <> ", notificationEmail="
            <> show cfgNotificationEmail
            <> ", asyncWorkers="
            <> show cfgAsyncWorkers
            <> " }"

{- | Default demo/test configuration with local SMTP and all optional capabilities disabled.
PRE-CONTRACT: None.
POST-CONTRACT: Produces a configuration that can be selectively overridden for tests or local runs.
-}
defaultDemoConfig :: DemoConfig
defaultDemoConfig =
    DemoConfig
        { cfgTgToken = Nothing
        , cfgTgChatId = Nothing
        , cfgAiApiKey = Nothing
        , cfgAiBaseUrl = Nothing
        , cfgSmtpHost = "127.0.0.1"
        , cfgSmtpPort = 1025
        , cfgSmtpLogin = ""
        , cfgSmtpPass = ""
        , cfgSmtpName = ""
        , cfgSmtpUseTls = False
        , cfgNotificationEmail = Nothing
        , cfgAsyncWorkers = 1
        }

{- | Read demo configuration from environment variables.
PRE-CONTRACT: None.
POST-CONTRACT: SMTP fields use defaults when their env vars are unset; optional fields (Telegram, AI, notification email) are Nothing when unset; the async worker count defaults to 1 when ASYNC_WORKERS is unset or unparseable.
-}
readDemoConfig :: IO DemoConfig
readDemoConfig = do
    cfgTgToken <- lookupEnvToText "TG_TOKEN"
    cfgTgChatId <- lookupEnvToText "TG_CHAT_ID"
    cfgAiApiKey <- lookupEnvToText "AI_API_KEY"
    cfgAiBaseUrl <- lookupEnvToText "AI_BASE_URL"
    cfgSmtpHost <- fmap (fromMaybe $ cfgSmtpHost defaultDemoConfig) (lookupEnv "SMTP_HOST")
    cfgSmtpPort <- fmap (fromMaybe (cfgSmtpPort defaultDemoConfig) . (>>= readMaybe)) (lookupEnv "SMTP_PORT")
    cfgSmtpLogin <- fmap (fromMaybe $ cfgSmtpLogin defaultDemoConfig) (lookupEnv "SMTP_LOGIN")
    cfgSmtpPass <- fmap (fromMaybe $ cfgSmtpPass defaultDemoConfig) (lookupEnv "SMTP_PASSWORD")
    cfgSmtpName <- fmap (fromMaybe $ cfgSmtpName defaultDemoConfig) (lookupEnv "SMTP_NAME")
    cfgSmtpUseTls <- fmap (fromMaybe (cfgSmtpUseTls defaultDemoConfig) . (>>= readMaybe)) (lookupEnv "SMTP_USE_TLS")
    cfgNotificationEmail <- lookupEnv "NOTIFICATION_EMAIL"
    cfgAsyncWorkers <- fmap (fromMaybe 1 . (>>= readMaybe)) (lookupEnv "ASYNC_WORKERS")
    pure DemoConfig{..}
  where
    -- \| Look up an environment variable and convert the result to Text.
    -- Empty strings are treated as unset.
    lookupEnvToText :: String -> IO (Maybe Text)
    lookupEnvToText = fmap (maybe Nothing (\s -> if null s then Nothing else Just (fromString s))) . lookupEnv

{- | Convert a DemoConfig into a DefaultAppConfig ready for 'newDefaultApp'.
Fields cfgTgChatId and cfgNotificationEmail are demo-specific and not passed through.
PRE-CONTRACT: None.
POST-CONTRACT: All shared fields are mapped; demo-only fields are discarded.
-}
demoConfigToAppConfig :: AllServices -> DemoConfig -> LAD.DefaultAppConfig AllServices
demoConfigToAppConfig services cfg =
    LAD.DefaultAppConfig
        { LAD.cfgPgConnectionString = testConnectionString
        , LAD.cfgPgConnectionStringReadOnly = Nothing
        , LAD.cfgPgPoolMaxResources = 10
        , LAD.cfgBotConfigs = case cfgTgToken cfg of
            Just token -> [("demo-bot", token)]
            Nothing -> []
        , LAD.cfgAiApiKey = cfgAiApiKey cfg
        , LAD.cfgAiBaseUrl = cfgAiBaseUrl cfg
        , LAD.cfgMailCreds = MailCreds (cfgSmtpHost cfg) (cfgSmtpPort cfg) (cfgSmtpLogin cfg) (cfgSmtpPass cfg) (cfgSmtpName cfg) (cfgSmtpUseTls cfg)
        , LAD.cfgExtraContext = HM.fromList [("env", "demo"), ("circus_name", "Lazy Circus")]
        , LAD.cfgSqlLogAction = Just putStrLn
        , LAD.cfgServiceLib = services
        }

{- | Run an action with a demo application, managing lifecycle and background workers.
PRE-CONTRACT: PostgreSQL must be reachable at 127.0.0.1:5432.
POST-CONTRACT: Worker threads (async pool, timer service, logger, service workers) are cancelled first
so in-flight connections are released; database connection pools are then released via
'destroyAllResources', which does not wait for in-flight users (acceptable after cancels).
-}
withDemoApp :: DemoConfig -> (DefaultApp AllServices -> IO ()) -> IO ()
withDemoApp cfg action = do
    setupDatabase
    let svcConfig = AllServicesConfig
            { simpleRequest = handleSimpleRequest
            , addExpressionRequest = handleAddExpressionRequest
            }
    (allServices, workers) <- mkAllServices svcConfig
    let appConfig = demoConfigToAppConfig allServices cfg
    app <- newDefaultApp appConfig
    let app' = app & toolDescriptionsL .~ allToolDescriptions
                   & toolCallExecL .~ mkToolCallExec allServices
    bracket
        ( do
            workerThreads <- runAllWorkers workers
            logThread <- async $ runRIO (logAppFromDefaultApp app') logWorker
            asyncThread <- async $ runRIO app' (runAsyncWorkerPool (cfgAsyncWorkers cfg) (runDefaultPerformer . run @Script @AllServices))
            timerThread <- async $ runRIO app' (runTimerService @Script @AllServices)
            pure (app', logThread, asyncThread, timerThread, workerThreads)
        )
        ( \(_, logThread, asyncThread, timerThread, workerThreads) -> do
            cancel asyncThread
            cancel timerThread
            cancel logThread
            mapM_ cancel workerThreads
            destroyAllResources (pgDbPool app')
            mapM_ destroyAllResources (pgDbPoolReadOnly app')
        )
        (action . fst5)
  where
    -- \| Extract the first element of a 5-tuple.
    fst5 (a, _, _, _, _) = a

{- | Execute a scenario program against the demo application's default performer stack.
PRE-CONTRACT: The DefaultApp must have a live database connection.
POST-CONTRACT: Returns the scenario result.
-}
runDemoScenario :: DefaultApp AllServices -> ScenarioProgram Script AllServices a -> IO a
runDemoScenario app scenario = runRIO app $ runDefaultPerformer $ run @Script @AllServices scenario

------------------------------------------------------------------------
-- Database helpers
------------------------------------------------------------------------

-- | Connection string for the PostgreSQL admin user.
adminConnectionString :: ByteString
adminConnectionString = encodeUtf8 "host=127.0.0.1 port=5432 user=postgres password=my_password dbname=postgres"

-- | Connection string for the admin user targeting the test database.
adminTestConnectionString :: ByteString
adminTestConnectionString = encodeUtf8 "host=127.0.0.1 port=5432 user=postgres password=my_password dbname=lazy_circus_test"

-- | Connection string for the application user targeting the test database.
testConnectionString :: ByteString
testConnectionString = encodeUtf8 "host=127.0.0.1 port=5432 user=lazy_circus_app password=my_password dbname=lazy_circus_test"

{- | Connect to PostgreSQL with retries, waiting 250ms between attempts.
PRE-CONTRACT: None.
POST-CONTRACT: Returns a live connection after successful connect.
-}
retryConnect :: ByteString -> IO Connection
retryConnect connectionString = go 20
  where
    -- \| Retry with exponential back-off capped at the remaining attempt count.
    go :: Int -> IO Connection
    go attempts =
        connectPostgreSQL connectionString `catchAny` \err ->
            case CE.fromException err of
                Just (_ :: AsyncException) -> throwIO err
                Nothing
                    | attempts <= 1 -> throwIO err
                    | otherwise -> do
                        threadDelay 250000
                        go (attempts - 1)

-- | Drop and recreate the test database, terminating existing connections first.
recreateTestDatabase :: Connection -> IO ()
recreateTestDatabase conn = do
    let killSessions =
            Query
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity \
                \WHERE datname = 'lazy_circus_test' AND pid <> pg_backend_pid()"
    void (query_ conn killSessions :: IO [Only Bool])
    void $ execute_ conn (Query "DROP DATABASE IF EXISTS lazy_circus_test")
    void $ execute_ conn (Query "CREATE DATABASE lazy_circus_test")

{- | Set up the test database: connect as admin, recreate DB, run migrations.
PRE-CONTRACT: PostgreSQL must be reachable at 127.0.0.1:5432.
POST-CONTRACT: The test database exists with the expected schema.
-}
setupDatabase :: IO ()
setupDatabase = do
    bracket (retryConnect adminConnectionString) close $ \adminConn -> do
        recreateTestDatabase adminConn

    bracket (retryConnect adminTestConnectionString) close $ \bootstrapConn -> do
        void $ execute_ bootstrapConn (Query "SET client_min_messages TO warning")
        void $ execute_ bootstrapConn (Query (encodeUtf8 migration))
