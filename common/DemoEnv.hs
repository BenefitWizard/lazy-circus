{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Constructs a DefaultApp runtime environment for the Lazy Circus demo application.
module DemoEnv
    ( DemoConfig(..)
    , readDemoConfig
    , withDemoApp
    , runDemoScenario
    ) where

import RIO
import RIO.HashMap qualified as HM
import RIO.Map qualified as M
import Text.Read (readMaybe)
import RIO.Process (mkDefaultProcessContext)

import Control.Exception (AsyncException)
import qualified Control.Exception as CE

import Database.PostgreSQL.Simple (Connection, Only(..), close, connectPostgreSQL, execute_, query_)
import Database.PostgreSQL.Simple.Types (Query(..))

import Network.HTTP.Client.TLS (newTlsManager)

import LazyCircus.App.Default
import LazyCircus.App.Log hiding (genLogFunc, logContext, logFunc, logQueue)
import LazyCircus.AsyncWorker (runAsyncWorker)
import LazyCircus.Performer.Default (runDefaultScenario, runDefaultPerformer)
import LazyCircus.Scenario (ScenarioProgram)
import LazyCircus.Script (Script)
import LazyCircus.Telegram (makeBotEnv)

import OpenAI.V1 (getClientEnv, makeMethods)
import Telegram.Bot.API (Token(..))

import Servant.Auth.Server (defaultJWTSettings)
import Crypto.JOSE (genJWK, KeyMaterialGenParam(OctGenParam))

import Common (migration)
import System.Environment (lookupEnv)
import System.IO (putStrLn)

-- | Configuration values for the demo application, read from environment variables.
data DemoConfig = DemoConfig
    { cfgTgToken           :: Maybe Text   -- ^ Telegram bot token
    , cfgTgChatId          :: Maybe Text   -- ^ Telegram chat ID for notifications
    , cfgAiApiKey          :: Maybe Text   -- ^ AI service API key
    , cfgAiBaseUrl         :: Maybe Text   -- ^ AI service base URL
    , cfgSmtpHost          :: String       -- ^ SMTP server hostname
    , cfgSmtpPort          :: Int          -- ^ SMTP server port
    , cfgSmtpLogin         :: String       -- ^ SMTP login username
    , cfgSmtpPass          :: String       -- ^ SMTP login password
    , cfgSmtpName          :: String       -- ^ sender display name for outgoing emails
    , cfgSmtpUseTls        :: Bool         -- ^ whether to use STARTTLS for sending
    , cfgNotificationEmail :: Maybe String -- ^ email address for notifications
    }

-- | Masks sensitive fields; tokens and passwords shown only as present/absent.
instance Show DemoConfig where
    show DemoConfig{..} = "DemoConfig { tgToken=" <> show (isJust cfgTgToken)
        <> ", tgChatId=" <> show cfgTgChatId
        <> ", aiApiKey=" <> show (isJust cfgAiApiKey)
        <> ", aiBaseUrl=" <> show cfgAiBaseUrl
        <> ", smtpHost=" <> show cfgSmtpHost
        <> ", smtpPort=" <> show cfgSmtpPort
        <> ", smtpLogin=" <> show cfgSmtpLogin
        <> ", smtpPass=" <> (if null cfgSmtpPass then "\"\"" else "\"***\"")
        <> ", smtpName=" <> show cfgSmtpName
        <> ", smtpUseTls=" <> show cfgSmtpUseTls
        <> ", notificationEmail=" <> show cfgNotificationEmail
        <> " }"

-- | Read demo configuration from environment variables.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: SMTP fields use defaults when their env vars are unset; optional fields (Telegram, AI, notification email) are Nothing when unset.
readDemoConfig :: IO DemoConfig
readDemoConfig = DemoConfig
    <$> lookupEnvToText "TG_TOKEN"
    <*> lookupEnvToText "TG_CHAT_ID"
    <*> lookupEnvToText "AI_API_KEY"
    <*> lookupEnvToText "AI_BASE_URL"
    <*> fmap (fromMaybe "127.0.0.1") (lookupEnv "SMTP_HOST")
    <*> fmap (fromMaybe 1025 . (>>= readMaybe)) (lookupEnv "SMTP_PORT")
    <*> fmap (fromMaybe "") (lookupEnv "SMTP_LOGIN")
    <*> fmap (fromMaybe "") (lookupEnv "SMTP_PASSWORD")
    <*> fmap (fromMaybe "") (lookupEnv "SMTP_NAME")
    <*> fmap (fromMaybe False . (>>= readMaybe)) (lookupEnv "SMTP_USE_TLS")
    <*> lookupEnv "NOTIFICATION_EMAIL"
  where
    -- | Look up an environment variable and convert the result to Text.
    -- Empty strings are treated as unset.
    lookupEnvToText :: String -> IO (Maybe Text)
    lookupEnvToText = fmap (maybe Nothing (\s -> if null s then Nothing else Just (fromString s))) . lookupEnv

-- | Construct a full DefaultApp runtime from the given configuration and existing connection.
-- PRE-CONTRACT: The connection must be live and properly configured.
-- POST-CONTRACT: The returned DefaultApp shares the given connection; closing it is the caller's responsibility.
createDemoAppWithConn :: DemoConfig -> Connection -> IO DefaultApp
createDemoAppWithConn cfg conn = do

    manager <- newTlsManager

    botEnvsVal <- case cfgTgToken cfg of
        Just token -> do
            botEnv <- makeBotEnv manager (Token token, "demo-bot")
            pure $ M.singleton "demo-bot" botEnv
        Nothing -> pure mempty

    aiMethodsVal <- case cfgAiApiKey cfg of
        Just apiKey -> do
            let baseUrl = fromMaybe "https://api.deepseek.com" (cfgAiBaseUrl cfg)
            ce <- getClientEnv baseUrl
            pure $ makeMethods ce apiKey Nothing Nothing
        Nothing -> do
            ce <- getClientEnv "https://example.com"
            pure $ makeMethods ce "dummy-key" Nothing Nothing

    jwk <- genJWK (OctGenParam 256)
    let jwtSettingsVal = defaultJWTSettings jwk

    logQueueVal <- newTQueueIO
    asyncTasksVal <- newTQueueIO
    processCtx <- mkDefaultProcessContext

    let logFuncVal = mkLogFunc $ \_cs _src _lvl msg ->
            hPutBuilder stdout (getUtf8Builder msg)
    let genLogFuncVal = mkGLogFunc $ \_cs msg ->
            atomically $ writeTQueue logQueueVal msg

    pure App
        { logFunc = logFuncVal
        , genLogFunc = genLogFuncVal
        , pgDbConnection = conn
        , pgDbConnectionReadOnly = Nothing
        , appMainDb = conn
        , appProcessContext = processCtx
        , botEnvs = botEnvsVal
        , jwtSettings = jwtSettingsVal
        , logQueue = logQueueVal
        , extraContext = HM.fromList [("env", "demo"), ("circus_name", "Lazy Circus")]
        , logContext = mempty
        , mailCreds = MailCreds (cfgSmtpHost cfg) (cfgSmtpPort cfg) (cfgSmtpLogin cfg) (cfgSmtpPass cfg) (cfgSmtpName cfg) (cfgSmtpUseTls cfg)
        , asyncTasks = asyncTasksVal
        , aiMethods = aiMethodsVal
        , sqlLogAction = putStrLn
        }

-- | Run an action with a demo application, managing lifecycle and background workers.
-- PRE-CONTRACT: PostgreSQL must be reachable.
-- POST-CONTRACT: Database connection is closed and background threads are cancelled after the action.
withDemoApp :: DemoConfig -> (DefaultApp -> IO ()) -> IO ()
withDemoApp cfg action =
    bracketOnError setupDatabase close $ \conn -> do
        app <- createDemoAppWithConn cfg conn
        bracket
            (do
                logThread <- async $ runRIO (logAppFromDefaultApp app) logWorker
                asyncThread <- async $ runRIO app (runAsyncWorker (runDefaultPerformer . runDefaultScenario))
                pure (app, logThread, asyncThread)
            )
            (\(_, logThread, asyncThread) -> do
                cancel asyncThread
                cancel logThread
            )
            (action . fst3)
  where
    -- | Extract the first element of a 3-tuple.
    fst3 (a, _, _) = a

-- | Execute a scenario program against the demo application's default performer stack.
-- PRE-CONTRACT: The DefaultApp must have a live database connection.
-- POST-CONTRACT: Returns the scenario result.
runDemoScenario :: DefaultApp -> ScenarioProgram Script a -> IO a
runDemoScenario app scenario = runRIO app $ runDefaultPerformer $ runDefaultScenario scenario

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

-- | Connect to PostgreSQL with retries, waiting 250ms between attempts.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Returns a live connection after successful connect.
retryConnect :: ByteString -> IO Connection
retryConnect connectionString = go 20
  where
    -- | Retry with exponential back-off capped at the remaining attempt count.
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
    let killSessions = Query
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity \
            \WHERE datname = 'lazy_circus_test' AND pid <> pg_backend_pid()"
    void (query_ conn killSessions :: IO [Only Bool])
    void $ execute_ conn (Query "DROP DATABASE IF EXISTS lazy_circus_test")
    void $ execute_ conn (Query "CREATE DATABASE lazy_circus_test")

-- | Set up the test database: connect as admin, recreate DB, run migrations, connect as app user.
-- PRE-CONTRACT: PostgreSQL must be reachable at 127.0.0.1:5432.
-- POST-CONTRACT: Returns a live connection as the lazy_circus_app user.
setupDatabase :: IO Connection
setupDatabase = do
    bracket (retryConnect adminConnectionString) close $ \adminConn -> do
        recreateTestDatabase adminConn

    bracket (retryConnect adminTestConnectionString) close $ \bootstrapConn -> do
        void $ execute_ bootstrapConn (Query "SET client_min_messages TO warning")
        void $ execute_ bootstrapConn (Query (encodeUtf8 migration))

    retryConnect testConnectionString
