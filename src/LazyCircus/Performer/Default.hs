{-# LANGUAGE ScopedTypeVariables #-}

-- | Production interpreter that wires every LazyCircus free language
-- (Telegram, Mail, AI, Database) into concrete RIO-based handler instances.
--
-- PURPOSE: Provide the default performer newtype and all its interpreter
-- instances so that a ScenarioProgram over the Script coproduct can be
-- executed against real services (Telegram API, SMTP, OpenAI, PostgreSQL).
-- SCOPE: DefaultPerformer newtype, environment retargeting, NoBotConfigured
-- exception, and interpreter instances for TelegramScriptPerformer,
-- MailScriptPerformer, AILangPerformer, ScenarioPerformer, and KnownHowToEval.
module LazyCircus.Performer.Default (
    DefaultPerformer (..),
    changeEnv,
    NoBotConfigured (..),
    -- runDefaultScenario,
) where

import Control.Monad.Free.Church qualified as FC
import LazyCircus.AI (askAI, solveWithAgentLoop)
import LazyCircus.App.Default
import LazyCircus.App.Log
import LazyCircus.App.Service (HasToolDescriptions (..), callViaServiceLib)
import LazyCircus.AsyncWorker (scheduleAsyncAction)
import LazyCircus.AsyncWorker.Types (HasScheduledActions)
import LazyCircus.DB.Class (HasPgConnection (..), HasPgConnectionReadOnly (..))
import LazyCircus.DB.WithConnection (AppWithConnection (..))
import LazyCircus.Mail qualified as Mail
import LazyCircus.Scenario
import LazyCircus.Scene.AI.Class (AILangPerformer (..), runAI)
import LazyCircus.Scene.DB.Class (runDB)
import LazyCircus.Scene.Mail.Class (MailScriptPerformer (..), runMail)
import LazyCircus.Scene.Telegram.Class (TelegramScriptPerformer (..), runTelegram)
import LazyCircus.Script
import LazyCircus.Telegram qualified as TG
import LazyCircus.Telegram.Types (AppWithBotEnv (..))
import RIO
import RIO.Map qualified as M
import RIO.Time (getCurrentTime)

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

-- | Delegates every Telegram operation to the concrete Telegram client
-- running inside the supplied AppWithBotEnv.
instance TelegramScriptPerformer (DefaultPerformer (AppWithBotEnv (DefaultApp serviceLib))) where
    sendMessage' = TG.sendMessage
    getFile' = TG.getFile
    getBotName' = TG.getBotName
    scheduleMessages' = TG.scheduleMessages
    setBotCommands' = TG.setBotCommands
    setMessageReaction' = TG.setMessageReaction
    answerCallbackQuery' = TG.answerCallbackQuery
    editMessageText' = TG.editMessageText

-- | Delegates mail operations to the concrete SMTP-backed mail service.
instance MailScriptPerformer (DefaultPerformer (DefaultApp serviceLib)) where
    sendMail' = Mail.sendMail
    makeMail' = Mail.makeMail

-- | Routes AI requests through the configured OpenAI client.
instance AILangPerformer (DefaultPerformer (DefaultApp serviceLib)) where
    ask' = askAI
    solveWithAgent' = solveWithAgentLoop

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
    runSafely' scenario = do
        v <- try $ run scenario
        pure $ case v of
            Left e -> Left e
            Right a -> Right a
    log' cs = sublangLog cs "Scenario"

    getDateTime' = liftIO getCurrentTime

    runAsync' = scheduleAsyncAction
    getExtraContext' = view extraContextL

    callService' = callViaServiceLib

    withLogContext' values act =
        local (logContextL %~ (`putInLoggingContext` values)) (run act)

-- | Dispatches the Script coproduct to the correct domain interpreter
-- (Telegram, Mail, AI, or Database) using evalScriptDefault.
instance KnownHowToEval Script (DefaultPerformer (DefaultApp serviceLib)) where
    evalSubScript = evalScriptDefault

-- | Pattern-matches on the Script coproduct and delegates each variant to its
-- corresponding language runner (runTelegram, runMail, runAI, runDB).
-- PRE-CONTRACT: Telegram scripts require the requested bot name to be present
-- in the environment's botEnvs map; DB scripts require a configured PostgreSQL
-- connection.
-- POST-CONTRACT: Each script variant is executed in its own interpreter context
-- with the appropriate environment projection applied.
evalScriptDefault :: Script a -> DefaultPerformer (DefaultApp serviceLib) a
evalScriptDefault (TelegramScriptDef name scr) = do
    botEnvs <- view botEnvsL
    case M.lookup name botEnvs of
        Nothing -> throwIO $ NoBotConfigured name
        Just botEnv -> changeEnv (AppWithBotEnv botEnv) (runTelegram scr)
evalScriptDefault (MailScriptDef scr) = runMail scr
evalScriptDefault (AIScriptDef descs scr) = local (toolDescriptionsL .~ descs) $ runAI scr
evalScriptDefault (DBScriptDef db mode scr) = do
    conn <- case mode of
        ReadWrite -> view postgresL
        ReadOnly -> do
            mReadOnlyConn <- view postgresReadOnlyL
            fallbackConn <- view postgresL
            pure $ fromMaybe fallbackConn mReadOnlyConn
    changeEnv (AppWithConnection conn) (runDB db mode scr)
