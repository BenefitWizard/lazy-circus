{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE RecordWildCards #-}

{- | PURPOSE: Concrete application runtime environment (DefaultApp) for the LazyCircus backend.
Gathers every capability required by interpreters, workers, and bot flows into a single
RIO-reader record, then wires up all Has* lens-based class instances.

SCOPE: Environment construction, capability wiring, and small map-building helpers used
during startup. Does NOT contain business logic, interpreter definitions, or routing.
-}
module LazyCircus.App.Default
    ( -- * Types
      Tokens
    , BotNames
    , BotEnvs
    , ExtraContext
    , MailCreds(..)
    , PgMainDB
      -- * Configuration
    , DefaultAppConfig(..)
    , newDefaultApp
      -- * Application environment
    , DefaultApp(..)
      -- * Capability classes
    , HasMainDb(..)
    , HasJWTSettings(..)
    , HasBotEnvs(..)
    , HasExtraContext(..)
    , HasMailCreds(..)
      -- * Helpers
    , constructHFromMList
    , constructFromMList
    , constructTokens
    , logAppFromDefaultApp
    ) where

import Crypto.JOSE (KeyMaterialGenParam (OctGenParam), genJWK)
import Crypto.Random
import qualified Control.Exception as E (onException)
import Database.PostgreSQL.Simple (Connection, close, connectPostgreSQL)
import LazyCircus.AI (HasAIMethods (..))
import LazyCircus.App.Log hiding (genLogFunc, logContext, logFunc, logQueue)
import LazyCircus.App.Service
import LazyCircus.AsyncWorker.Types (HasScheduledActions (..), ScheduledActions)
import LazyCircus.DB.Class (HasPgConnection (..), HasPgConnectionReadOnly (..))
import LazyCircus.Scene.DB.Class (HasDbConnection (..))
import LazyCircus.Script (Script)
import LazyCircus.Telegram (makeBotEnv)
import LazyCircus.Telegram.Types (BotEnv)
import Network.HTTP.Client.TLS (newTlsManager)
import Network.Mail.SMTP
import OpenAI.V1 (Methods, getClientEnv, makeMethods)
import RIO
import RIO.HashMap qualified as HM
import RIO.Map qualified as M
import RIO.Process (HasProcessContext (..), ProcessContext, mkDefaultProcessContext)
import Servant.Auth.Server (JWTSettings, defaultJWTSettings)
import System.IO (putStrLn)  -- String-based, used as default sqlLogAction
import Telegram.Bot.API (Token (..))

-- | Runtime mapping from logical bot names to Telegram bot tokens.
type Tokens = Map Text Token

-- | Runtime mapping from logical bot names to their configured Telegram display names.
type BotNames = Map Text Text

-- | Runtime mapping from logical bot names to initialized Telegram bot environments.
type BotEnvs = Map Text BotEnv

-- | Arbitrary text configuration values exposed to control and bot flows.
type ExtraContext = HashMap Text Text

-- | SMTP credentials used by runtime mail helpers and interpreters.
data MailCreds = MailCreds
    { mailHost     :: String  -- ^ SMTP server hostname
    , mailPort     :: Int     -- ^ SMTP server port number
    , mailLogin    :: String  -- ^ SMTP authentication username
    , mailPassword :: String  -- ^ SMTP authentication password
    , mailName     :: String  -- ^ human-readable sender display name
    , mailUseTls   :: Bool    -- ^ whether to enable TLS for the SMTP connection
    }
    deriving (Generic)

-- | Masks the password field; shows all other fields in full.
instance Show MailCreds where
    show MailCreds{..} =
        "MailCreds { mailHost=" <> show mailHost
        <> ", mailPort=" <> show mailPort
        <> ", mailLogin=" <> show mailLogin
        <> ", mailPassword=\"" <> (if null mailPassword then "" else "***") <> "\""
        <> ", mailName=" <> show mailName
        <> ", mailUseTls=" <> show mailUseTls
        <> " }"

-- | Raw configuration values needed to construct a fully initialized DefaultApp.
-- The smart constructor 'newDefaultApp' reads these values and performs all
-- necessary IO (connecting to databases, creating queues, initializing bot
-- environments, generating JWT keys) to produce a ready-to-use DefaultApp.
data DefaultAppConfig serviceLib = DefaultAppConfig
    { cfgPgConnectionString :: !ByteString
    -- ^ PostgreSQL connection string for the primary read-write database
    , cfgPgConnectionStringReadOnly :: !(Maybe ByteString)
    -- ^ optional PostgreSQL connection string for a read-only replica
    , cfgBotConfigs :: ![(Text, Text)]
    -- ^ (botName, botToken) pairs for Telegram bots to initialize
    , cfgAiApiKey :: !(Maybe Text)
    -- ^ OpenAI-compatible API key. When 'Nothing', AI calls will fail at runtime
    -- with a connection error. Consider using 'Maybe' in the app if AI is optional.
    , cfgAiBaseUrl :: !(Maybe Text)
    -- ^ OpenAI-compatible base URL; defaults to "https://api.deepseek.com"
    , cfgMailCreds :: !MailCreds
    -- ^ SMTP credentials for outgoing mail
    , cfgExtraContext :: !ExtraContext
    -- ^ arbitrary key-value configuration exposed to flows
    , cfgSqlLogAction :: !(Maybe (String -> IO ()))
    -- ^ optional SQL query tracer; defaults to putStrLn when Nothing
    , cfgServiceLib :: !serviceLib
    -- ^ collection of in-process service handlers
    }

-- | Legacy alias for the primary application database handle kept to preserve DefaultApp shape.
type PgMainDB = Connection

-- | Capability for accessing the main database handle from a reader environment.
class HasMainDb env where
    mainDbL :: Lens' env PgMainDB

-- | Capability for accessing JWT settings from a reader environment.
class HasJWTSettings env where
    jwtSettingsL :: Lens' env JWTSettings

{- | Concrete backend runtime environment threaded through startup, workers, and interpreters.
Includes read-write and optional read-only database connections, and a configurable SQL logging
action used by the DebugInterpreter to trace Beam queries during development.
-}
data DefaultApp serviceLib = App
    { logFunc :: LogFunc
    -- ^ RIO standard logging function
    , genLogFunc :: GLogFunc AppLogMsgWithContext
    -- ^ generic structured log writer
    , pgDbConnection :: Connection
    -- ^ primary read-write PostgreSQL connection
    , pgDbConnectionReadOnly :: Maybe Connection
    -- ^ optional read-only PostgreSQL replica connection
    , appMainDb :: PgMainDB
    -- ^ main database handle for legacy DB service layer
    , appProcessContext :: ProcessContext
    -- ^ RIO process context for subprocess management
    , botEnvs :: BotEnvs
    -- ^ mapping of logical bot names to Telegram environments
    , jwtSettings :: JWTSettings
    -- ^ servant-auth JWT configuration
    , logQueue :: LogQueue
    -- ^ shared queue feeding the background log worker
    , extraContext :: ExtraContext
    -- ^ arbitrary key-value configuration exposed to flows
    , logContext :: LoggingContext
    -- ^ structured key-value logging metadata
    , mailCreds :: MailCreds
    -- ^ SMTP credentials for outgoing mail
    , asyncTasks :: ScheduledActions Script serviceLib
    -- ^ queue of deferred scenario programs
    , aiMethods :: Methods
    -- ^ OpenAI client methods for AI completions
    , sqlLogAction :: String -> IO ()
    -- ^ optional SQL query tracer used during development
    , serviceLib :: serviceLib
    -- ^ collection of in-process service handlers
    }

{- | Construct a fully initialized DefaultApp from raw configuration values.
Connects to PostgreSQL, initializes Telegram bot environments, creates the
AI client, generates JWT settings, and sets up all internal queues.
If an IO step fails after opening a connection, opened connections are
automatically closed before rethrowing the exception.
PRE-CONTRACT: cfgPgConnectionString points to a reachable PostgreSQL instance
with the expected schema already migrated.
POST-CONTRACT: Returns a DefaultApp with live connections and initialized
resources. The caller is responsible for closing connections via bracket or
similar cleanup mechanism.
-}
newDefaultApp :: DefaultAppConfig serviceLib -> IO (DefaultApp serviceLib)
newDefaultApp config = do
    conn <- connectPostgreSQL (cfgPgConnectionString config)
    E.onException (go conn) (close conn)
  where
    go conn = do
        mReadOnlyConn <- traverse connectPostgreSQL (cfgPgConnectionStringReadOnly config)
        E.onException (buildRest conn mReadOnlyConn) (mapM_ close mReadOnlyConn)

    buildRest conn mReadOnlyConn = do
        manager <- newTlsManager
        botEnvsVal <- fmap M.fromList $ forM (cfgBotConfigs config) $ \(name, tokenText) -> do
            botEnv <- makeBotEnv manager (Token tokenText, name)
            pure (name, botEnv)
        aiMethodsVal <- case cfgAiApiKey config of
            Just apiKey -> do
                let baseUrl = fromMaybe "https://api.deepseek.com" (cfgAiBaseUrl config)
                ce <- getClientEnv baseUrl
                pure $ makeMethods ce apiKey Nothing Nothing
            Nothing -> do
                ce <- getClientEnv "http://127.0.0.1:1"
                pure $ makeMethods ce "not-configured" Nothing Nothing
        jwk <- genJWK (OctGenParam 256)
        let jwtSettingsVal = defaultJWTSettings jwk
        logQueueVal <- newTQueueIO
        asyncTasksVal <- newTQueueIO
        processCtx <- mkDefaultProcessContext
        let logFuncVal = mkLogFunc $ \_cs _src _lvl msg ->
                hPutBuilder stdout (getUtf8Builder msg)
        let genLogFuncVal = mkGLogFunc $ \_cs msg ->
                atomically $ writeTQueue logQueueVal msg
        let sqlLog = fromMaybe putStrLn (cfgSqlLogAction config)
        pure App
            { logFunc = logFuncVal
            , genLogFunc = genLogFuncVal
            , pgDbConnection = conn
            , pgDbConnectionReadOnly = mReadOnlyConn
            , appMainDb = conn
            , appProcessContext = processCtx
            , botEnvs = botEnvsVal
            , jwtSettings = jwtSettingsVal
            , logQueue = logQueueVal
            , extraContext = cfgExtraContext config
            , logContext = mempty
            , mailCreds = cfgMailCreds config
            , asyncTasks = asyncTasksVal
            , aiMethods = aiMethodsVal
            , sqlLogAction = sqlLog
            , serviceLib = cfgServiceLib config
            }

-- | Capability for accessing initialized Telegram bot environments from a reader environment.
class HasBotEnvs env where
    botEnvsL :: Lens' env BotEnvs

-- | Capability for accessing extra text configuration values from a reader environment.
class HasExtraContext env where
    extraContextL :: Lens' env (HashMap Text Text)

-- | Capability for accessing SMTP credentials from a reader environment.
class HasMailCreds env where
    mailCredsL :: Lens' env MailCreds

-- | Satisfies HasLogFunc by delegating to the logFunc field.
instance HasLogFunc (DefaultApp serviceLib) where
    logFuncL = lens logFunc (\x y -> x{logFunc = y})

-- | Satisfies HasGLogFunc with AppLogMsgWithContext as the generic message type.
instance HasGLogFunc (DefaultApp serviceLib) where
    type GMsg (DefaultApp serviceLib) = AppLogMsgWithContext
    gLogFuncL = lens genLogFunc (\x y -> x{genLogFunc = y})

-- | Satisfies HasProcessContext by delegating to the appProcessContext field.
instance HasProcessContext (DefaultApp serviceLib) where
    processContextL = lens appProcessContext (\x y -> x{appProcessContext = y})

-- | Exposes the primary read-write PostgreSQL connection through the shared HasPgConnection capability.
instance HasPgConnection (DefaultApp serviceLib) where
    postgresL = lens pgDbConnection (\x y -> x{pgDbConnection = y})

-- | Satisfies HasDbConnection by sharing the primary PostgreSQL connection with the Scene DB layer.
instance HasDbConnection (DefaultApp serviceLib) where
    dbConnectionL = lens pgDbConnection (\x y -> x{pgDbConnection = y})

-- | Expose the optional read-only PostgreSQL connection through the shared HasPgConnectionReadOnly capability.
instance HasPgConnectionReadOnly (DefaultApp serviceLib) where
    postgresReadOnlyL = lens pgDbConnectionReadOnly (\x y -> x{pgDbConnectionReadOnly = y})

-- | Satisfies HasMainDb by delegating to the appMainDb field.
instance HasMainDb (DefaultApp serviceLib) where
    mainDbL = lens appMainDb (\x y -> x{appMainDb = y})

-- | Satisfies HasJWTSettings by delegating to the jwtSettings field.
instance HasJWTSettings (DefaultApp serviceLib) where
    jwtSettingsL = lens jwtSettings (\x y -> x{jwtSettings = y})

-- | Satisfies HasBotEnvs by delegating to the botEnvs field.
instance HasBotEnvs (DefaultApp serviceLib) where
    botEnvsL = lens botEnvs (\x y -> x{botEnvs = y})

-- | Satisfies HasMailCreds by delegating to the mailCreds field.
instance HasMailCreds (DefaultApp serviceLib) where
    mailCredsL = lens mailCreds (\x y -> x{mailCreds = y})

-- | Satisfies HasExtraContext by delegating to the extraContext field.
instance HasExtraContext (DefaultApp serviceLib) where
    extraContextL = lens extraContext (\x y -> x{extraContext = y})

-- | Satisfies HasLogQueue by delegating to the logQueue field.
instance HasLogQueue (DefaultApp serviceLib) where
    logQueueL = lens logQueue (\x y -> x{logQueue = y})

-- | Satisfies HasLoggingContext by delegating to the logContext field.
instance HasLoggingContext (DefaultApp serviceLib) where
    logContextL = lens logContext (\x y -> x{logContext = y})

-- -- | Satisfies HasScheduledActions for Script by delegating to the asyncTasks field.
-- class HasScheduledActions script sl env | env -> script sl where
--     scheduledActionsL :: Lens' env (ScheduledActions script sl)
instance HasScheduledActions Script serviceLib (DefaultApp serviceLib) where
    scheduledActionsL = lens asyncTasks (\x y -> x{asyncTasks = y})

-- | Satisfies HasAIMethods by delegating to the aiMethods field.
instance HasAIMethods (DefaultApp serviceLib) where
    aiMethodsL = lens aiMethods (\x y -> x{aiMethods = y})

-- | Satisfies HasServiceLib by delegating to the serviceLib field.
instance HasServiceLib (DefaultApp serviceLib) serviceLib where
    serviceLibL = lens serviceLib (\x y -> x{serviceLib = y})

-- | Drop missing values from an association list while preserving keys for present entries.
constructHFromMList :: [(Text, Maybe a)] -> HashMap Text a
constructHFromMList vals' = HM.fromList $ mapMaybe attachKey vals'
  where
    -- \| Keep only entries with a present value.
    attachKey (k, Just v) = Just (k, v)
    attachKey _ = Nothing

-- | Drop missing values from an association list and collect present entries into an ordered map.
constructFromMList :: [(Text, Maybe a)] -> Map Text a
constructFromMList vals' = M.fromList $ mapMaybe attachKey vals'
  where
    -- \| Keep only entries with a present value.
    attachKey (k, Just v) = Just (k, v)
    attachKey _ = Nothing

-- | Convert optional raw bot token text values into concrete Telegram tokens.
constructTokens :: [(Text, Maybe Text)] -> Tokens
constructTokens tokens' = constructFromMList tokens' & M.map Token

{- | Project the logging subset of DefaultApp needed by the shared log worker.
Creates a fresh GLogFunc that prints to stdout rather than copying the
queue-writer from DefaultApp, so that logWorker is the sole printing path.
POST-CONTRACT: Returned LogApp shares the same logFunc and logQueue as the input;
its genLogFunc writes directly to stdout.
-}
logAppFromDefaultApp :: DefaultApp serviceLib -> LogApp
logAppFromDefaultApp app =
    let
        logFunc' = app ^. logFuncL
        genLogFunc' = mkGLogFunc $ \_cs msg ->
            hPutBuilder stdout (getUtf8Builder (display msg))
        logQueue' = app ^. logQueueL
     in
        LogApp logFunc' genLogFunc' logQueue'

{- | ORPHAN: MonadRandom and RIO are from separate packages.
LAW: getRandomBytes preserves length: n == ByteString.length (getRandomBytes n — holds by delegation to the Crypto.Random instance.
-}
instance MonadRandom (RIO env) where
    -- TODO: switch to seeded pseudo-random generator
    getRandomBytes = liftIO . getRandomBytes
