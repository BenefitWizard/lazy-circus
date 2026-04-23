{-# LANGUAGE FunctionalDependencies #-}

{- | PURPOSE: Concrete application runtime environment (DefaultApp) for the LazyCircus backend.
Gathers every capability required by interpreters, workers, and bot flows into a single
RIO-reader record, then wires up all Has* lens-based class instances.

SCOPE: Environment construction, capability wiring, and small map-building helpers used
during startup. Does NOT contain business logic, interpreter definitions, or routing.
-}
module LazyCircus.App.Default where

import Crypto.Random
import Database.PostgreSQL.Simple (Connection)
import LazyCircus.AI (HasAIMethods (..))
import LazyCircus.App.Log hiding (genLogFunc, logContext, logFunc, logQueue)
import LazyCircus.App.Service
import LazyCircus.AsyncWorker.Types (HasScheduledActions (..), ScheduledActions)
import LazyCircus.DB.Class (HasPgConnection (..), HasPgConnectionReadOnly (..))
import LazyCircus.Scene.DB.Class (HasDbConnection (..))
import LazyCircus.Script (Script)
import LazyCircus.Telegram.Types (BotEnv)
import Network.Mail.SMTP
import OpenAI.V1 (Methods)
import RIO
import RIO.HashMap qualified as HM
import RIO.Map qualified as M
import RIO.Process
import Servant.Auth.Server (JWTSettings)
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
    { mailHost :: String
    -- ^ SMTP server hostname
    , mailPort :: Int
    -- ^ SMTP server port number
    , mailLogin :: String
    -- ^ SMTP authentication username
    , mailPassword :: String
    -- ^ SMTP authentication password
    , mailName :: String
    -- ^ human-readable sender display name
    , mailUseTls :: Bool
    -- ^ whether to enable TLS for the SMTP connection
    }
    deriving (Generic, Show)

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
