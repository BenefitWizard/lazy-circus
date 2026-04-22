{-# LANGUAGE AllowAmbiguousTypes #-}

module LazyCircus.Scenario (
    DbMode (..),
    Scenario (..),
    ScenarioProgram,
    ScenarioPerformer (..),
    run,
    evalScript,
    throw,
    runSafely,
    getDateTime,
    log,
    logInfo,
    logWarn,
    logError,
    logSensitive,
    getExtraContext,
    readFromExtraContext,
    getFeatureFlag,
    withLogContext,
    withLogEntry,
    with2LogEntries,
    runAsync,
) where

import Control.Monad.Free.Church qualified as FC
import Data.HashMap.Strict qualified as HM
import GHC.Stack (CallStack, HasCallStack, callStack)
import LazyCircus.App.Log
import LazyCircus.Scene.Log
import RIO hiding (log, logError, logInfo, logWarn)
import RIO.Time (UTCTime)

-- | Database connection mode used to select between read-write and read-only connections.
data DbMode = ReadWrite | ReadOnly deriving (Eq, Show)

{- | Scenario-layer instruction set that adds orchestration concerns around embedded effect scripts.
Logging operations are unified through LogLangF embedding.
-}
data Scenario s a where
    EvalScript :: s b -> (b -> a) -> Scenario s a
    GetDateTime :: (UTCTime -> a) -> Scenario s a
    Throw :: (Exception e) => e -> (b -> a) -> Scenario s a
    RunSafely :: (Exception e) => ScenarioProgram s b -> (Either e b -> a) -> Scenario s a
    ScenarioLogMsg :: CallStack -> AppLogMsg -> a -> Scenario s a
    ScenarioWithLogCtx :: [(Text, Text)] -> ScenarioProgram s b -> (b -> a) -> Scenario s a
    GetExtraContext :: (HashMap Text Text -> a) -> Scenario s a
    RunAsync :: ScenarioProgram s () -> a -> Scenario s a

instance Functor (Scenario s) where
    fmap f (EvalScript scr g) = EvalScript scr (f . g)
    fmap f (Throw e g) = Throw e (f . g)
    fmap f (RunSafely act g) = RunSafely act (f . g)
    fmap f (GetDateTime g) = GetDateTime (f . g)
    fmap f (ScenarioLogMsg cs msg g) = ScenarioLogMsg cs msg (f g)
    fmap f (GetExtraContext g) = GetExtraContext (f . g)
    fmap f (ScenarioWithLogCtx values act g) = ScenarioWithLogCtx values act (f . g)
    fmap f (RunAsync act g) = RunAsync act (f g)

-- | Church-encoded free program over the Scenario instruction set.
type ScenarioProgram s = FC.F (Scenario s)

-- | Performer contract for executing ScenarioProgram instructions in a concrete monad.
class (Monad m) => ScenarioPerformer sc m where
    onEvalScript :: sc b -> m b
    throw' :: (Exception e) => e -> m b
    runSafely' :: (Exception e) => ScenarioProgram sc a -> m (Either e a)
    getDateTime' :: m UTCTime
    log' :: CallStack -> AppLogMsg -> m ()
    getExtraContext' :: m (HashMap Text Text)
    withLogContext' :: [(Text, Text)] -> ScenarioProgram sc a -> m a
    runAsync' :: ScenarioProgram sc () -> m ()

{- | Fold a ScenarioProgram into any monad that implements ScenarioPerformer.
PRE-CONTRACT: None
POST-CONTRACT: Executes each Scenario instruction using the corresponding ScenarioPerformer method.
-}
run :: forall sc m a. (ScenarioPerformer sc m) => ScenarioProgram sc a -> m a
run = FC.iterM go
 where
  go :: Scenario sc (m a) -> m a
  go (EvalScript scr next) = do
    b <- onEvalScript scr
    next b
  go (Throw e next) = do
    b <- throw' @sc e
    next b
  go (RunSafely act next) = do
    res <- runSafely' act
    next res
  go (GetDateTime next) = do
    b <- getDateTime' @sc
    next b
  go (ScenarioLogMsg cs msg next) = do
    log' @sc cs msg
    next
  go (GetExtraContext next) = do
    b <- getExtraContext' @sc
    next b
  go (ScenarioWithLogCtx values act next) = do
    v <- withLogContext' values act
    next v
  go (RunAsync act next) = do
    runAsync' act
    next

{- | Lift an embedded Script instruction into the ScenarioProgram layer.
PRE-CONTRACT: None
POST-CONTRACT: The returned program evaluates the supplied Script through the active ScenarioPerformer.
-}
evalScript :: s a -> ScenarioProgram s a
evalScript script = FC.liftF $ EvalScript script id

{- | Raise an exception through the control interpreter.
PRE-CONTRACT: None
POST-CONTRACT: The returned program delegates exception delivery to the active interpreter.
-}
throw :: (Exception e) => e -> ScenarioProgram s a
throw e = FC.liftF $ Throw e id

{- | Execute a control program while capturing exceptions of the requested type.
PRE-CONTRACT: None
POST-CONTRACT: Returns a program that yields Either e a according to interpreter-defined exception handling.
-}
runSafely :: (Exception e) => ScenarioProgram s a -> ScenarioProgram s (Either e a)
runSafely act = FC.liftF $ RunSafely act id

{- | Request the current UTC time from the interpreter.
PRE-CONTRACT: None
POST-CONTRACT: Produces the current time value supplied by the active interpreter.
-}
getDateTime :: ScenarioProgram s UTCTime
getDateTime = FC.liftF $ GetDateTime id

{- | Emit a structured application log message through the control interpreter.
PRE-CONTRACT: None
POST-CONTRACT: Schedules the supplied log message for interpreter-defined handling.
-}
log :: (HasCallStack) => AppLogMsg -> ScenarioProgram s ()
log msg = FC.liftF $ ScenarioLogMsg callStack msg ()

{- | Emit an informational application log message.
PRE-CONTRACT: None
POST-CONTRACT: Logs the supplied message at the App severity level.
-}
logInfo :: (HasCallStack) => Text -> ScenarioProgram s ()
logInfo msg = FC.liftF $ ScenarioLogMsg callStack (AppLogMsg msg) ()

{- | Emit a warning-level application log message.
PRE-CONTRACT: None
POST-CONTRACT: Logs the supplied message at the warning severity level.
-}
logWarn :: (HasCallStack) => Text -> ScenarioProgram s ()
logWarn msg = FC.liftF $ ScenarioLogMsg callStack (WarnLogMsg msg) ()

{- | Emit an error-level application log message.
PRE-CONTRACT: None
POST-CONTRACT: Logs the supplied message at the error severity level.
-}
logError :: (HasCallStack) => Text -> ScenarioProgram s ()
logError msg = FC.liftF $ ScenarioLogMsg callStack (ErrorLogMsg msg) ()

{- | Emit a sensitive log message intended for debug-only sinks.
PRE-CONTRACT: None
POST-CONTRACT: Logs the supplied message using the sensitive log variant.
-}
logSensitive :: (HasCallStack) => Text -> ScenarioProgram s ()
logSensitive msg = FC.liftF $ ScenarioLogMsg callStack (SensitiveLogMsg msg) ()

{- | Read the interpreter-provided extra context map.
PRE-CONTRACT: None
POST-CONTRACT: Returns the complete extra-context map exposed by the active interpreter.
-}
getExtraContext :: ScenarioProgram s (HashMap Text Text)
getExtraContext = FC.liftF $ GetExtraContext id

{- | Look up a single key inside the interpreter extra-context map.
PRE-CONTRACT: None
POST-CONTRACT: Returns Just value when the requested key exists and Nothing otherwise.
-}
readFromExtraContext :: Text -> ScenarioProgram s (Maybe Text)
readFromExtraContext key = FC.liftF $ GetExtraContext (HM.lookup key)

{- | Interpret an extra-context key as a boolean feature flag.
PRE-CONTRACT: None
POST-CONTRACT: Returns True only when the stored value is exactly "true"; otherwise returns False.
-}
getFeatureFlag :: Text -> ScenarioProgram s Bool
getFeatureFlag key = FC.liftF $ GetExtraContext (isEnabled . HM.lookup key)
 where
  isEnabled r = case r of
    Nothing -> False
    Just v -> v == "true"

{- | Run a control program with additional logging context entries.
PRE-CONTRACT: None
POST-CONTRACT: The supplied action observes the merged log context chosen by the interpreter.
-}
withLogContext :: [(Text, Text)] -> ScenarioProgram s a -> ScenarioProgram s a
withLogContext values act = FC.liftF $ ScenarioWithLogCtx values act id

{- | Add a single showable value to the logging context for the duration of an action.
PRE-CONTRACT: None
POST-CONTRACT: The supplied action runs with one additional key/value log entry.
-}
withLogEntry :: (Show a) => Text -> a -> ScenarioProgram s b -> ScenarioProgram s b
withLogEntry key value act = FC.liftF $ ScenarioWithLogCtx values act id
 where
  values = [(key, tshow value)]

{- | Add two showable values to the logging context for the duration of an action.
PRE-CONTRACT: None
POST-CONTRACT: The supplied action runs with both key/value log entries added to the context.
-}
with2LogEntries :: (Show a, Show b) => ((Text, a), (Text, b)) -> ScenarioProgram s z -> ScenarioProgram s z
with2LogEntries (e1, e2) = withLogContext values
 where
  values =
    [ (fst e1, tshow $ snd e1)
    , (fst e2, tshow $ snd e2)
    ]

{- | Schedule a control action for asynchronous execution.
PRE-CONTRACT: None
POST-CONTRACT: Returns a program that delegates asynchronous scheduling to the active interpreter.
-}
runAsync :: ScenarioProgram s () -> ScenarioProgram s ()
runAsync act = FC.liftF $ RunAsync act ()

{- | Enable LogLangF smart constructors to work directly in ScenarioProgram.
Maps LogLangF operations to the unified Scenario constructors.
-}
instance HasLogLang (Scenario sc) (ScenarioProgram sc) where
    embedLog (LogMsg cs msg next) = ScenarioLogMsg cs msg next
    embedLog (WithLogCtx values prog next) = ScenarioWithLogCtx values prog next
