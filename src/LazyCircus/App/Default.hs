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
      -- * Configuration
    , DefaultAppConfig(..)
    , newDefaultApp
      -- * Application environment
    , DefaultApp(..)
      -- * Capability classes
    , HasPgPool(..)
    , HasPgPoolReadOnly(..)
    , HasJWTSettings(..)
    , HasBotEnvs(..)
    , HasExtraContext(..)
    , HasMailCreds(..)
    , HasHttpManager(..)
      -- * Helpers
    , constructHFromMList
    , constructFromMList
    , constructTokens
    , logAppFromDefaultApp
    ) where

import Crypto.JOSE (KeyMaterialGenParam (OctGenParam), genJWK)
import Crypto.Random
import qualified Control.Exception as E (onException)
import Data.Pool (Pool, defaultPoolConfig, destroyAllResources, newPool, withResource)
import Database.PostgreSQL.Simple (Connection, close, connectPostgreSQL)
import LazyCircus.AI (HasAIMethods (..))
import LazyCircus.App.Log hiding (genLogFunc, logContext, logFunc, logQueue)
import LazyCircus.App.Service
import LazyCircus.AsyncWorker.Types (HasScheduledActions (..), ScheduledActions)
import LazyCircus.Script (Script)
import LazyCircus.Telegram (makeBotEnv)
import LazyCircus.Telegram.Types (BotEnv)
import Network.HTTP.Client (Manager)
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
    , cfgPgPoolMaxResources :: !Int
    -- ^ cap on pooled PostgreSQL connections in total across all stripes;
    -- must be at least 1 (validated by 'newDefaultApp')
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

-- | Capability for accessing the read-write PostgreSQL connection pool from a reader environment.
class HasPgPool env where
    pgPoolL :: Lens' env (Pool Connection)

-- | Capability for accessing the optional read-only PostgreSQL connection pool from a reader environment.
class HasPgPoolReadOnly env where
    pgPoolReadOnlyL :: Lens' env (Maybe (Pool Connection))

-- | Capability for accessing JWT settings from a reader environment.
class HasJWTSettings env where
    jwtSettingsL :: Lens' env JWTSettings

{- | Concrete backend runtime environment threaded through startup, workers, and interpreters.
Includes read-write and optional read-only PostgreSQL connection pools, and a configurable SQL
logging action used by the DebugInterpreter to trace Beam queries during development.
-}
data DefaultApp serviceLib = App
    { logFunc :: LogFunc
    -- ^ RIO standard logging function
    , genLogFunc :: GLogFunc AppLogMsgWithContext
    -- ^ generic structured log writer
    , pgDbPool :: Pool Connection
    -- ^ pool of read-write PostgreSQL connections; checkout blocks when the
    -- configured cap is exhausted
    , pgDbPoolReadOnly :: Maybe (Pool Connection)
    -- ^ optional pool of read-only PostgreSQL replica connections with the
    -- same cap semantics as 'pgDbPool'
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
    , appToolDescriptions :: [ToolDescription]
    -- ^ tool descriptions available to AI interpreters
    , toolCallExec :: ToolCallExec
    -- ^ closure that dispatches named tool calls with JSON arguments
    , httpManager :: Manager
    -- ^ shared TLS connection manager for HTTP client requests
    }

{- | Construct a fully initialized DefaultApp from raw configuration values.
Creates PostgreSQL connection pools, initializes Telegram bot environments, creates the
AI client, generates JWT settings, and sets up all internal queues.
If an IO step fails after creating the pools, created pools are automatically
destroyed before rethrowing the exception.
PRE-CONTRACT: cfgPgConnectionString points to a reachable PostgreSQL instance
with the expected schema already migrated, and cfgPgPoolMaxResources >= 1.
POST-CONTRACT: Returns a DefaultApp with live pools and initialized resources;
each configured pool is probed at construction so an unreachable database fails
startup. The caller is responsible for releasing the pools via
'destroyAllResources' or a similar cleanup mechanism.
-}
newDefaultApp :: DefaultAppConfig serviceLib -> IO (DefaultApp serviceLib)
newDefaultApp config = do
    when (cfgPgPoolMaxResources config < 1) $
        throwString $
            "newDefaultApp: cfgPgPoolMaxResources must be >= 1, got "
                <> show (cfgPgPoolMaxResources config)
    rwPool <- newPool $ defaultPoolConfig (connectPostgreSQL (cfgPgConnectionString config)) close poolKeepOpenTime (cfgPgPoolMaxResources config)
    E.onException (go rwPool) (destroyAllResources rwPool)
  where
    -- | Seconds an idle pooled connection stays open before being reaped.
    poolKeepOpenTime = 30

    go rwPool = do
        withResource rwPool (\_ -> pure ())
        mReadOnlyPool <- traverse mkReadOnlyPool (cfgPgConnectionStringReadOnly config)
        E.onException (buildRest rwPool mReadOnlyPool) (mapM_ destroyAllResources mReadOnlyPool)

    -- | Create the read-only replica pool and probe it so an unreachable
    -- replica fails construction.
    mkReadOnlyPool connectionString = do
        pool <- newPool $ defaultPoolConfig (connectPostgreSQL connectionString) close poolKeepOpenTime (cfgPgPoolMaxResources config)
        E.onException (withResource pool (\_ -> pure ())) (destroyAllResources pool)
        pure pool

    buildRest rwPool mReadOnlyPool = do
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
                hPutBuilder stdout (getUtf8Builder msg <> "\n")
        let genLogFuncVal = mkGLogFunc $ \_cs msg ->
                atomically $ writeTQueue logQueueVal msg
        let sqlLog = fromMaybe putStrLn (cfgSqlLogAction config)
        pure App
            { logFunc = logFuncVal
            , genLogFunc = genLogFuncVal
            , pgDbPool = rwPool
            , pgDbPoolReadOnly = mReadOnlyPool
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
            , appToolDescriptions = []
            , toolCallExec = ToolCallExec $ \_ _ -> fail "ToolCallExec not initialized: set via toolCallExecL after newDefaultApp"
            , httpManager = manager
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

-- | Capability for accessing the shared HTTP connection manager from a reader environment.
class HasHttpManager env where
    httpManagerL :: Lens' env Manager

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

-- | Exposes the read-write PostgreSQL connection pool through the shared HasPgPool capability.
instance HasPgPool (DefaultApp serviceLib) where
    pgPoolL = lens pgDbPool (\x y -> x{pgDbPool = y})

-- | Exposes the optional read-only PostgreSQL connection pool through the shared HasPgPoolReadOnly capability.
instance HasPgPoolReadOnly (DefaultApp serviceLib) where
    pgPoolReadOnlyL = lens pgDbPoolReadOnly (\x y -> x{pgDbPoolReadOnly = y})

-- | Satisfies HasJWTSettings by delegating to the jwtSettings field.
instance HasJWTSettings (DefaultApp serviceLib) where
    jwtSettingsL = lens jwtSettings (\x y -> x{jwtSettings = y})

-- | Satisfies HasBotEnvs by delegating to the botEnvs field.
instance HasBotEnvs (DefaultApp serviceLib) where
    botEnvsL = lens botEnvs (\x y -> x{botEnvs = y})

-- | Satisfies HasMailCreds by delegating to the mailCreds field.
instance HasMailCreds (DefaultApp serviceLib) where
    mailCredsL = lens mailCreds (\x y -> x{mailCreds = y})

-- | Satisfies HasHttpManager by delegating to the httpManager field.
instance HasHttpManager (DefaultApp serviceLib) where
    httpManagerL = lens httpManager (\x y -> x{httpManager = y})

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

-- | Satisfies HasToolDescriptions by delegating to the appToolDescriptions field.
instance HasToolDescriptions (DefaultApp serviceLib) where
    toolDescriptionsL = lens appToolDescriptions (\x y -> x{appToolDescriptions = y})

-- | Satisfies HasToolCallExec by delegating to the toolCallExec field.
instance HasToolCallExec (DefaultApp serviceLib) where
    toolCallExecL = lens toolCallExec (\x y -> x{toolCallExec = y})

-- | Drop missing values from an association list while preserving keys for present entries.
constructHFromMList :: [(Text, Maybe a)] -> HashMap Text a
constructHFromMList vals' = HM.fromList $ mapMaybe attachKey vals'
  where
    -- | Keep only entries with a present value.
    attachKey (k, Just v) = Just (k, v)
    attachKey _ = Nothing

-- | Drop missing values from an association list and collect present entries into an ordered map.
constructFromMList :: [(Text, Maybe a)] -> Map Text a
constructFromMList vals' = M.fromList $ mapMaybe attachKey vals'
  where
    -- | Keep only entries with a present value.
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
            hPutBuilder stdout (getUtf8Builder (display msg) <> "\n")
        logQueue' = app ^. logQueueL
     in
        LogApp logFunc' genLogFunc' logQueue'

-- | ORPHAN: MonadRandom and RIO are from separate packages.
-- LAW: getRandomBytes preserves length: holds — n == ByteString.length (getRandomBytes n) by delegation to the Crypto.Random instance.
instance MonadRandom (RIO env) where
    -- TODO: switch to seeded pseudo-random generator
    getRandomBytes = liftIO . getRandomBytes
