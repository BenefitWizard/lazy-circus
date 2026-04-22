{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}

--   PURPOSE: Define a reusable logging effect language that can be embedded into any sub-language, providing unified slogInfo/slogWarn/slogError/slogSensitive and swithLogCtx operations across DBScript, TelegramScript, CryptoScript, MailScript, AIScript, and ScenarioProgram.
--   SCOPE: LogLangF functor, HasLogLang typeclass with functional dependency, polymorphic smart constructors, and the handleLogLang interpreter helper.
--   DEPENDS: M-LIB-APP-LOG

-- | Reusable logging sub-language for all backend effect languages.
module LazyCircus.Scene.Log (
    LogLangF (..),
    HasLogLang (..),
    slogInfo,
    slogWarn,
    slogError,
    slogSensitive,
    swithLogCtx,
    handleLogLang,
)
where

import Control.Monad.Free.Church (F)
import Control.Monad.Free.Class (MonadFree, liftF)
import GHC.Stack (CallStack, HasCallStack, callStack)
import LazyCircus.App.Log (AppLogMsg (..), HasLogQueue, HasLoggingContext, LoggingContext, logContextL, putInLoggingContext, sublangLog)
import RIO

{- | Effect functor for logging operations that can be embedded into any sub-language.
The 'prog' type parameter represents the host program type (e.g., DBScript db).
-}
data LogLangF prog a where
    LogMsg :: CallStack -> AppLogMsg -> a -> LogLangF prog a
    WithLogCtx :: [(Text, Text)] -> prog b -> (b -> a) -> LogLangF prog a

instance Functor (LogLangF prog) where
    fmap f (LogMsg cs msg next) = LogMsg cs msg (f next)
    fmap f (WithLogCtx values prog next) = WithLogCtx values prog (f . next)

{- | Typeclass that relates a functor 'f' to its program type 'prog', enabling
polymorphic logging operations across all sub-languages.
The functional dependency ensures that given 'f', the 'prog' type is determined.
-}
class HasLogLang f prog | f -> prog where
    -- | Embed a LogLangF instruction into the host functor.
    embedLog :: LogLangF prog a -> f a

{- | Emit an informational log message from any sub-language.
Usage: @slogInfo "message" :: DBScript MainDb ()@
-}
slogInfo :: (HasCallStack, Functor f, MonadFree f m, HasLogLang f prog) => Text -> m ()
slogInfo msg = liftF $ embedLog $ LogMsg callStack (AppLogMsg msg) ()

{- | Emit a warning log message from any sub-language.
Usage: @slogWarn "warning" :: DBScript MainDb ()@
-}
slogWarn :: (HasCallStack, Functor f, MonadFree f m, HasLogLang f prog) => Text -> m ()
slogWarn msg = liftF $ embedLog $ LogMsg callStack (WarnLogMsg msg) ()

{- | Emit an error log message from any sub-language.
Usage: @slogError "error" :: DBScript MainDb ()@
-}
slogError :: (HasCallStack, Functor f, MonadFree f m, HasLogLang f prog) => Text -> m ()
slogError msg = liftF $ embedLog $ LogMsg callStack (ErrorLogMsg msg) ()

{- | Emit a sensitive log message from any sub-language.
Usage: @slogSensitive "sensitive" :: DBScript MainDb ()@
-}
slogSensitive :: (HasCallStack, Functor f, MonadFree f m, HasLogLang f prog) => Text -> m ()
slogSensitive msg = liftF $ embedLog $ LogMsg callStack (SensitiveLogMsg msg) ()

{- | Run a sub-program with additional logging context entries.
Inner context values override outer values for the same keys.
-}
swithLogCtx :: (Functor f, MonadFree f m, HasLogLang f prog) => [(Text, Text)] -> prog b -> m b
swithLogCtx values prog = liftF $ embedLog $ WithLogCtx values prog id

{- | Unified interpreter for LogLangF that handles logging and context operations.
Takes a language tag (e.g., "DB", "Telegram") and a runner for the host program.
Usage: @handleLogLang "DB" runDB logOp@
-}
handleLogLang ::
    ( HasLogQueue env
    , HasLoggingContext env
    , MonadReader env m
    , MonadIO m
    ) =>
    Text ->
    (forall x. prog x -> m x) ->
    LogLangF prog (m b) ->
    m b
handleLogLang langTag runProg = \case
    LogMsg cs msg next -> do
        sublangLog cs langTag msg
        next
    WithLogCtx values prog next -> do
        logContext <- view logContextL
        let updatedContext = putInLoggingContext logContext values
        result <- local (logContextL .~ updatedContext) (runProg prog)
        next result
