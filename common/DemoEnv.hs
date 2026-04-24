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

import Database.PostgreSQL.Simple (Connection, Only (..), close, connectPostgreSQL, execute_, query_)
import Database.PostgreSQL.Simple.Types (Query (..))

import LazyCircus.App.Default hiding (cfgAiApiKey, cfgAiBaseUrl, DefaultAppConfig)
import LazyCircus.App.Default qualified as LAD (DefaultAppConfig (..))
import LazyCircus.App.Log hiding (genLogFunc, logContext, logFunc, logQueue)
import LazyCircus.AsyncWorker (runAsyncWorker)
import LazyCircus.Performer.Default (runDefaultPerformer)
import LazyCircus.Scenario (run)
import LazyCircus.Script (Script)
import LazyCircus.Scenario (ScenarioProgram)
import LazyCircus.Script (Script)

import Common (migration)
import LazyCircus.App.Service
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
        }

{- | Read demo configuration from environment variables.
PRE-CONTRACT: None.
POST-CONTRACT: SMTP fields use defaults when their env vars are unset; optional fields (Telegram, AI, notification email) are Nothing when unset.
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
demoConfigToAppConfig :: DemoConfig -> LAD.DefaultAppConfig NoServiceLib
demoConfigToAppConfig cfg =
    LAD.DefaultAppConfig
        { LAD.cfgPgConnectionString = testConnectionString
        , LAD.cfgPgConnectionStringReadOnly = Nothing
        , LAD.cfgBotConfigs = case cfgTgToken cfg of
            Just token -> [("demo-bot", token)]
            Nothing -> []
        , LAD.cfgAiApiKey = cfgAiApiKey cfg
        , LAD.cfgAiBaseUrl = cfgAiBaseUrl cfg
        , LAD.cfgMailCreds = MailCreds (cfgSmtpHost cfg) (cfgSmtpPort cfg) (cfgSmtpLogin cfg) (cfgSmtpPass cfg) (cfgSmtpName cfg) (cfgSmtpUseTls cfg)
        , LAD.cfgExtraContext = HM.fromList [("env", "demo"), ("circus_name", "Lazy Circus")]
        , LAD.cfgSqlLogAction = Just putStrLn
        , LAD.cfgServiceLib = NoServiceLib
        }

{- | Run an action with a demo application, managing lifecycle and background workers.
PRE-CONTRACT: PostgreSQL must be reachable at 127.0.0.1:5432.
POST-CONTRACT: Background threads are cancelled and database connections are closed after the action completes.
-}
withDemoApp :: DemoConfig -> (DefaultApp NoServiceLib -> IO ()) -> IO ()
withDemoApp cfg action = do
    setupDatabase
    let appConfig = demoConfigToAppConfig cfg
    app <- newDefaultApp appConfig
    bracket
        ( do
            logThread <- async $ runRIO (logAppFromDefaultApp app) logWorker
            asyncThread <- async $ runRIO app (runAsyncWorker (runDefaultPerformer . run @Script @NoServiceLib))
            pure (app, logThread, asyncThread)
        )
        ( \(app', logThread, asyncThread) -> do
            cancel asyncThread
            cancel logThread
            close (pgDbConnection app')
            mapM_ close (pgDbConnectionReadOnly app')
        )
        (action . fst3)
  where
    -- \| Extract the first element of a 3-tuple.
    fst3 (a, _, _) = a

{- | Execute a scenario program against the demo application's default performer stack.
PRE-CONTRACT: The DefaultApp must have a live database connection.
POST-CONTRACT: Returns the scenario result.
-}
runDemoScenario :: DefaultApp NoServiceLib -> ScenarioProgram Script NoServiceLib a -> IO a
runDemoScenario app scenario = runRIO app $ runDefaultPerformer $ run @Script @NoServiceLib scenario

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
