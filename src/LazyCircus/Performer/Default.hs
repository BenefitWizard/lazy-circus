{-# LANGUAGE ScopedTypeVariables #-}

-- | Production interpreter that wires every LazyCircus free language
-- (Telegram, Mail, AI, Database, HTTP) into concrete RIO-based handler instances.
--
-- PURPOSE: Provide the default performer newtype and all its interpreter
-- instances so that a ScenarioProgram over the Script coproduct can be
-- executed against real services (Telegram API, SMTP, OpenAI, PostgreSQL, HTTP).
-- SCOPE: DefaultPerformer newtype, environment retargeting, NoBotConfigured
-- exception, AppWithClientEnv wrapper, and interpreter instances for
-- TelegramScriptPerformer, MailScriptPerformer, AILangPerformer,
-- HTTPPerformer, ScenarioPerformer, and KnownHowToEval.
module LazyCircus.Performer.Default (
    DefaultPerformer (..),
    changeEnv,
    NoBotConfigured (..),
    AppWithClientEnv (..),
    -- runDefaultScenario,
) where

import Data.Pool (withResource)
import LazyCircus.AI (askAIContinuing, solveWithAgentLoopContinuing)
import LazyCircus.App.Default
import LazyCircus.App.Log
import LazyCircus.App.Service (HasToolDescriptions (..), callViaServiceLib)
import LazyCircus.AsyncWorker (scheduleAsyncAction)
import LazyCircus.AsyncWorker.Types (HasScheduledActions)
import LazyCircus.DB.WithConnection (AppWithConnection (..))
import LazyCircus.Mail qualified as Mail
import LazyCircus.Scenario
import LazyCircus.Scene.AI.Class (AILangPerformer (..), runAI)
import LazyCircus.Scene.DB.Class (runDB)
import LazyCircus.Scene.HTTP.Class (HTTPPerformer (..), runHTTP)
import LazyCircus.Scene.Mail.Class (MailScriptPerformer (..), runMail)
import LazyCircus.Scene.Log (timedAndLog)
import LazyCircus.Scene.Telegram.Class (TelegramScriptPerformer (..), runTelegram)
import LazyCircus.Script
import LazyCircus.Telegram qualified as TG
import LazyCircus.Telegram.Types (AppWithBotEnv (..))
import RIO
import RIO.Map qualified as M
import RIO.Time (getCurrentTime)
import Servant.Client (ClientEnv, mkClientEnv, runClientM)

-- | Newtype wrapper that equips a RIO environment with production interpreter instances.
newtype DefaultPerformer env a = DefaultPerformer
    { runDefaultPerformer :: RIO env a
    }
    deriving
        ( Applicative
        , Functor
        , Monad
        , MonadIO
        , MonadReader env
        , MonadUnliftIO
        )

-- | Re-target a production interpreter action to an outer environment via a projection.
changeEnv :: (outer -> inner) -> DefaultPerformer inner a -> DefaultPerformer outer a
changeEnv f (DefaultPerformer int) = DefaultPerformer (mapRIO f int)

-- | Raised when a Telegram script references a bot name that is absent from the runtime config.
newtype NoBotConfigured = NoBotConfigured Text
    deriving (Show)

-- | Allows NoBotConfigured to be thrown and caught as a typed exception.
instance Exception NoBotConfigured

-- | Attaches a concrete servant-client environment to an arbitrary application environment.
data AppWithClientEnv app = AppWithClientEnv
    { appClientEnv :: ClientEnv
    , appOuter     :: app
    }

-- ORPHAN: HasLogQueue for AppWithClientEnv, needed by runHTTP.
-- Delegates through appOuter.
instance (HasLogQueue app) => HasLogQueue (AppWithClientEnv app) where
    logQueueL = lens appOuter (\x y -> x{appOuter = y}) . logQueueL

-- ORPHAN: HasLoggingContext for AppWithClientEnv, needed by runHTTP.
-- Delegates through appOuter.
instance (HasLoggingContext app) => HasLoggingContext (AppWithClientEnv app) where
    logContextL = lens appOuter (\x y -> x{appOuter = y}) . logContextL

-- | Delegates every Telegram operation to the concrete Telegram client
-- running inside the supplied AppWithBotEnv.
-- IO operations are wrapped with 'timedAndLog' for automatic timing.
instance TelegramScriptPerformer (DefaultPerformer (AppWithBotEnv (DefaultApp serviceLib))) where
    sendMessage' req = timedAndLog "Telegram" "SendMessage" $ TG.sendMessage req
    sendDocument' req = timedAndLog "Telegram" "SendDocument" $ TG.sendDocument req
    getFile' fid = timedAndLog "Telegram" "GetFile" $ TG.getFile fid
    getBotName' = TG.getBotName  -- pure reader lookup, no IO timing needed
    scheduleMessages' reqs = timedAndLog "Telegram" "ScheduleMessages" $ TG.scheduleMessages reqs
    setBotCommands' cmds = timedAndLog "Telegram" "SetBotCommands" $ TG.setBotCommands cmds
    setMessageReaction' req = timedAndLog "Telegram" "SetMessageReaction" $ TG.setMessageReaction req
    answerCallbackQuery' req = timedAndLog "Telegram" "AnswerCallbackQuery" $ TG.answerCallbackQuery req
    editMessageText' req = timedAndLog "Telegram" "EditMessageText" $ TG.editMessageText req

-- | Delegates mail operations to the concrete SMTP-backed mail service.
-- IO operations are wrapped with 'timedAndLog' for automatic timing.
instance MailScriptPerformer (DefaultPerformer (DefaultApp serviceLib)) where
    sendMail' mail = timedAndLog "Mail" "SendMail" $ Mail.sendMail mail
    makeMail' to subj body = timedAndLog "Mail" "MakeMail" $ Mail.makeMail to subj body

-- | Routes AI requests through the configured OpenAI client.
-- IO operations are wrapped with 'timedAndLog' for automatic timing.
-- The continuing primitives are defined here; the stateless 'ask'' and
-- 'solveWithAgent'' are inherited from the class defaults.
instance AILangPerformer (DefaultPerformer (DefaultApp serviceLib)) where
    askContinuing' arg conv = timedAndLog "AI" "Ask" $ askAIContinuing arg conv
    solveWithAgentContinuing' arg conv = timedAndLog "AI" "SolveWithAgent" $ solveWithAgentLoopContinuing arg conv

-- | Executes servant-client actions against the real HTTP backend using the client environment.
-- Wrapped with 'timedAndLog' for automatic timing.
instance HTTPPerformer (DefaultPerformer (AppWithClientEnv (DefaultApp serviceLib))) where
    runClient' act = timedAndLog "HTTP" "RunClient" $ do
        clientEnv <- asks appClientEnv
        liftIO $ runClientM act clientEnv

-- | Full ScenarioPerformer instance for the DefaultPerformer.
-- Wires orchestration primitives (logging, async, service calls, datetime,
-- error handling, log-context) to their concrete RIO-based implementations.
instance
    ( KnownHowToEval script (DefaultPerformer (DefaultApp serviceLib))
    , HasScheduledActions script serviceLib (DefaultApp serviceLib)
    ) =>
    ScenarioPerformer script serviceLib (DefaultPerformer (DefaultApp serviceLib))
    where
    onEvalScript = evalSubScript

    -- onEvalScript = evalScriptDefault
    throw' = throwIO
    -- Async exceptions (ThreadKilled, UserInterrupt, Timeout, ...) are re-thrown
    -- rather than returned as 'Left', so a 'runSafely @SomeException' call can
    -- never silently absorb a thread-termination signal (which would leave the
    -- underlying effect, e.g. a DB write, in an indeterminate state while the
    -- action thread keeps running). Sync exceptions are returned as 'Left'.
    -- LAW: @Left@ is never an async exception.
    runSafely' scenario = do
        v <- try $ run scenario
        case v of
            Right a -> pure (Right a)
            Left e
                | Just (_ :: SomeAsyncException) <- fromException (toException e) -> throwIO e
                | otherwise -> pure (Left e)
    log' cs = sublangLog cs "Scenario"

    getDateTime' = liftIO getCurrentTime

    runAsync' = scheduleAsyncAction
    runArbitraryIO' = liftIO
    getExtraContext' = view extraContextL

    callService' = callViaServiceLib

    withLogContext' values act =
        local (logContextL %~ (`putInLoggingContext` values)) (run act)

-- | Dispatches the Script coproduct to the correct domain interpreter
-- (Telegram, Mail, AI, Database, HTTP) using evalScriptDefault.
instance KnownHowToEval Script (DefaultPerformer (DefaultApp serviceLib)) where
    evalSubScript = evalScriptDefault

-- | Pattern-matches on the Script coproduct and delegates each variant to its
-- corresponding language runner (runTelegram, runMail, runAI, runDB, runHTTP).
-- PRE-CONTRACT: Telegram scripts require the requested bot name to be present
-- in the environment's botEnvs map; DB scripts require a configured PostgreSQL
-- connection pool; HTTP scripts require a reachable BaseUrl.
-- POST-CONTRACT: Each script variant is executed in its own interpreter context
-- with the appropriate environment projection applied. A DB script checks out
-- one pooled connection for its entire duration, so 'withTransaction' inside
-- the script is safe.
evalScriptDefault :: Script a -> DefaultPerformer (DefaultApp serviceLib) a
evalScriptDefault (TelegramScriptDef name scr) = do
    botEnvs <- view botEnvsL
    case M.lookup name botEnvs of
        Nothing -> throwIO $ NoBotConfigured name
        Just botEnv -> changeEnv (AppWithBotEnv botEnv) (runTelegram scr)
evalScriptDefault (MailScriptDef scr) = runMail scr
evalScriptDefault (AIScriptDef descs scr) = local (toolDescriptionsL .~ descs) $ runAI scr
evalScriptDefault (DBScriptDef db mode scr) = do
    pool <- case mode of
        ReadWrite -> view pgPoolL
        ReadOnly -> do
            mReadOnlyPool <- view pgPoolReadOnlyL
            fallbackPool <- view pgPoolL
            pure $ fromMaybe fallbackPool mReadOnlyPool
    withRunInIO $ \runInIO ->
        withResource pool $ \conn ->
            runInIO $ changeEnv (AppWithConnection conn) (runDB db mode scr)
evalScriptDefault (HTTPScriptDef baseUrl scr) = do
    manager <- view httpManagerL
    let clientEnv = mkClientEnv manager baseUrl
    changeEnv (AppWithClientEnv clientEnv) (runHTTP scr)
