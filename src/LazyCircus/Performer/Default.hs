{-# LANGUAGE ScopedTypeVariables #-}

module LazyCircus.Performer.Default (
    DefaultPerformer (..),
    changeEnv,
    NoBotConfigured (..),
    runDefaultScenario,
) where

import Control.Monad.Free.Church qualified as FC
import LazyCircus.AI (askAI)
import LazyCircus.App.Default
import LazyCircus.App.Log
import LazyCircus.AsyncWorker (scheduleAsyncAction)
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

instance Exception NoBotConfigured

instance TelegramScriptPerformer (DefaultPerformer (AppWithBotEnv (DefaultApp serviceLib))) where
    sendMessage' = TG.sendMessage
    getFile' = TG.getFile
    getBotName' = TG.getBotName
    scheduleMessages' = TG.scheduleMessages
    setBotCommands' = TG.setBotCommands
    setMessageReaction' = TG.setMessageReaction
    answerCallbackQuery' = TG.answerCallbackQuery
    editMessageText' = TG.editMessageText

instance MailScriptPerformer (DefaultPerformer (DefaultApp serviceLib)) where
    sendMail' = Mail.sendMail
    makeMail' = Mail.makeMail

instance AILangPerformer (DefaultPerformer (DefaultApp serviceLib)) where
    ask' = askAI

-- | Execute a scenario program against the default runtime environment and its current performer stack.
runDefaultScenario :: forall serviceLib a. ScenarioProgram Script serviceLib a -> DefaultPerformer (DefaultApp serviceLib) a
runDefaultScenario = FC.iterM go
  where
    go :: Scenario Script serviceLib (DefaultPerformer (DefaultApp serviceLib) a) -> DefaultPerformer (DefaultApp serviceLib) a
    go (EvalScript script next) = do
        result <- evalScriptDefault script
        next result
    go (Throw e next) = do
        result <- throwIO e
        next result
    go (RunSafely act next) = do
        result <- try (runDefaultScenario act)
        next result
    go (GetDateTime next) = do
        now <- liftIO getCurrentTime
        next now
    go (ScenarioLogMsg cs msg next) = do
        sublangLog cs "Scenario" msg
        next
    go (ScenarioWithLogCtx values act next) = do
        result <- local (logContextL %~ (`putInLoggingContext` values)) (runDefaultScenario act)
        next result
    go (GetExtraContext next) = do
        ctx <- view extraContextL
        next ctx
    go (RunAsync act next) = do
        scheduleAsyncAction act
        next

evalScriptDefault :: Script a -> DefaultPerformer (DefaultApp serviceLib) a
evalScriptDefault (TelegramScriptDef name scr) = do
    botEnvs <- view botEnvsL
    case M.lookup name botEnvs of
        Nothing -> throwIO $ NoBotConfigured name
        Just botEnv -> changeEnv (AppWithBotEnv botEnv) (runTelegram scr)
evalScriptDefault (MailScriptDef scr) = runMail scr
evalScriptDefault (AIScriptDef scr) = runAI scr
evalScriptDefault (DBScriptDef db mode scr) = do
    conn <- case mode of
        ReadWrite -> view postgresL
        ReadOnly -> do
            mReadOnlyConn <- view postgresReadOnlyL
            fallbackConn <- view postgresL
            pure $ fromMaybe fallbackConn mReadOnlyConn
    changeEnv (AppWithConnection conn) (runDB db mode scr)
