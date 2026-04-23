{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE UndecidableInstances #-}

module LazyCircus.Performer (
    module LazyCircus.Performer,
    module LazyCircus.Scenario,
    module LazyCircus.Script,
) where

import LazyCircus.App.Log
import LazyCircus.Scenario
import LazyCircus.Scene.AI.Class (AILangPerformer, runAI)
import LazyCircus.Scene.DB.Class (DBScriptPerformer, runDB)
import LazyCircus.Scene.Mail.Class (MailScriptPerformer, runMail)
import LazyCircus.Scene.Telegram.Class (TelegramScriptPerformer, runTelegram)
import LazyCircus.Script
import RIO
import RIO.Time (getCurrentTime)

{- | Concrete 'ScenarioPerformer' for 'Script' that dispatches each sub-language
to its corresponding interpreter via pattern-match.

Infrastructure methods (throw, logging, time, etc.) are wired to standard
IO-based implementations.

PRE-CONTRACT: The target monad must provide performer instances for all
sub-languages (Telegram, Mail, AI, DB) as well as 'HasLogQueue',
and 'HasLoggingContext' in its reader environment.
POST-CONTRACT: Every 'evalScript' call is routed to the correct sub-interpreter,
and orchestration operations (throw, logging, time, async) are handled via IO.
-}
instance
    ( TelegramScriptPerformer m
    , MailScriptPerformer m
    , AILangPerformer m
    , DBScriptPerformer m
    , HasLogQueue env
    , HasLoggingContext env
    , MonadReader env m
    , MonadUnliftIO m
    ) =>
    ScenarioPerformer Script serviceLib m
    where
    onEvalScript (TelegramScriptDef _token scr) = runTelegram scr
    onEvalScript (MailScriptDef scr) = runMail scr
    onEvalScript (AIScriptDef scr) = runAI scr
    onEvalScript (DBScriptDef db mode scr) = runDB db mode scr

    throw' = throwIO
    {-# INLINE throw' #-}

    runSafely' = try . run
    {-# INLINE runSafely' #-}

    getDateTime' = getCurrentTime
    {-# INLINE getDateTime' #-}

    log' cs msg = sublangLog cs "Scenario" msg
    {-# INLINE log' #-}

    getExtraContext' = pure mempty
    {-# INLINE getExtraContext' #-}

    withLogContext' values act =
        local (logContextL %~ (`putInLoggingContext` values)) (run act)
    {-# INLINE withLogContext' #-}

    runAsync' act = void $ async (run act)
    {-# INLINE runAsync' #-}
