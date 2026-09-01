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
  runAsyncAfter,
  runArbitraryIO,
  callService,
  KnownHowToEval (..),
) where

import Control.Monad.Free.Church qualified as FC
import Data.HashMap.Strict qualified as HM
import GHC.Stack (CallStack, HasCallStack, callStack)
import LazyCircus.App.Log
import LazyCircus.App.Service qualified as S
import LazyCircus.Scene.Log
import RIO hiding (log, logError, logInfo, logWarn)
import RIO.Time (NominalDiffTime, UTCTime)

-- | Database connection mode used to select between read-write and read-only connections.
data DbMode = ReadWrite | ReadOnly deriving (Eq, Show)

{- | Scenario-layer instruction set that adds orchestration concerns around embedded effect scripts.
Logging operations are unified through LogLangF embedding.
-}
data Scenario script serviceLib a where
  EvalScript :: script b -> (b -> a) -> Scenario script serviceLib a
  GetDateTime :: (UTCTime -> a) -> Scenario script serviceLib a
  Throw :: (Exception e) => e -> (b -> a) -> Scenario script serviceLib a
  RunSafely :: (Exception e) => ScenarioProgram script serviceLib b -> (Either e b -> a) -> Scenario script serviceLib a
  ScenarioLogMsg :: CallStack -> AppLogMsg -> a -> Scenario script serviceLib a
  ScenarioWithLogCtx :: [(Text, Text)] -> ScenarioProgram script serviceLib b -> (b -> a) -> Scenario script serviceLib a
  GetExtraContext :: (HashMap Text Text -> a) -> Scenario script serviceLib a
  RunAsync :: ScenarioProgram script serviceLib () -> a -> Scenario script serviceLib a
  RunAsyncAfter :: NominalDiffTime -> ScenarioProgram script serviceLib () -> a -> Scenario script serviceLib a
  RunArbitraryIO :: IO b -> (b -> a) -> Scenario script serviceLib a
  CallService ::
    (S.IsInServiceLib serviceLib request response) =>
    request -> (response -> a) -> Scenario script serviceLib a

instance Functor (Scenario script serviceLib) where
  fmap f (EvalScript scr g) = EvalScript scr (f . g)
  fmap f (Throw e g) = Throw e (f . g)
  fmap f (RunSafely act g) = RunSafely act (f . g)
  fmap f (GetDateTime g) = GetDateTime (f . g)
  fmap f (ScenarioLogMsg cs msg g) = ScenarioLogMsg cs msg (f g)
  fmap f (GetExtraContext g) = GetExtraContext (f . g)
  fmap f (ScenarioWithLogCtx values act g) = ScenarioWithLogCtx values act (f . g)
  fmap f (RunAsync act g) = RunAsync act (f g)
  fmap f (RunAsyncAfter d act g) = RunAsyncAfter d act (f g)
  fmap f (RunArbitraryIO io g) = RunArbitraryIO io (f . g)
  fmap f (CallService req g) = CallService req (f . g)

-- | Church-encoded free program over the Scenario instruction set.
type ScenarioProgram script serviceLib = FC.F (Scenario script serviceLib)

-- | Performer contract for executing ScenarioProgram instructions in a concrete monad.
class (Monad m) => ScenarioPerformer script serviceLib m where
  onEvalScript :: script b -> m b
  throw' :: (Exception e) => e -> m b
  runSafely' :: (Exception e) => ScenarioProgram script serviceLib a -> m (Either e a)
  getDateTime' :: m UTCTime
  log' :: CallStack -> AppLogMsg -> m ()
  getExtraContext' :: m (HashMap Text Text)
  withLogContext' :: [(Text, Text)] -> ScenarioProgram script serviceLib a -> m a
  runAsync' :: ScenarioProgram script serviceLib () -> m ()
  runAsyncAfter' :: NominalDiffTime -> ScenarioProgram script serviceLib () -> m ()
  runArbitraryIO' :: IO a -> m a
  callService' :: (S.IsInServiceLib serviceLib request response) => request -> m response

{- | Fold a ScenarioProgram into any monad that implements ScenarioPerformer.
PRE-CONTRACT: None
POST-CONTRACT: Executes each Scenario instruction using the corresponding ScenarioPerformer method.
-}
run :: forall script serviceLib m a. (ScenarioPerformer script serviceLib m) => ScenarioProgram script serviceLib a -> m a
run = FC.iterM go
 where
  go :: Scenario script serviceLib (m a) -> m a
  go (EvalScript scr next) = do
    b <- onEvalScript @script @serviceLib scr
    next b
  go (Throw e next) = do
    b <- throw' @script @serviceLib e
    next b
  go (RunSafely act next) = do
    res <- runSafely' act
    next res
  go (GetDateTime next) = do
    b <- getDateTime' @script @serviceLib
    next b
  go (ScenarioLogMsg cs msg next) = do
    log' @script @serviceLib cs msg
    next
  go (GetExtraContext next) = do
    b <- getExtraContext' @script @serviceLib
    next b
  go (ScenarioWithLogCtx values act next) = do
    v <- withLogContext' values act
    next v
  go (RunAsync act next) = do
    runAsync' act
    next
  go (RunAsyncAfter d act next) = do
    runAsyncAfter' d act
    next
  go (RunArbitraryIO io next) = do
    b <- runArbitraryIO' @script @serviceLib io
    next b
  go (CallService req next) = do
    res <- callService' @script @serviceLib req
    next res

{- | Lift an embedded Script instruction into the ScenarioProgram layer.
PRE-CONTRACT: None
POST-CONTRACT: The returned program evaluates the supplied Script through the active ScenarioPerformer.
-}
evalScript :: script a -> ScenarioProgram script serviceLib a
evalScript script = FC.liftF $ EvalScript script id

{- | Raise an exception through the control interpreter.
PRE-CONTRACT: None
POST-CONTRACT: The returned program delegates exception delivery to the active interpreter.
-}
throw :: (Exception e) => e -> ScenarioProgram script serviceLib a
throw e = FC.liftF $ Throw e id

{- | Execute a control program while capturing exceptions of the requested type.
PRE-CONTRACT: None
POST-CONTRACT: Returns a program that yields Either e a according to interpreter-defined exception handling.
-}
runSafely :: (Exception e) => ScenarioProgram script serviceLib a -> ScenarioProgram script serviceLib (Either e a)
runSafely act = FC.liftF $ RunSafely act id

{- | Request the current UTC time from the interpreter.
PRE-CONTRACT: None
POST-CONTRACT: Produces the current time value supplied by the active interpreter.
-}
getDateTime :: ScenarioProgram script serviceLib UTCTime
getDateTime = FC.liftF $ GetDateTime id

{- | Emit a structured application log message through the control interpreter.
PRE-CONTRACT: None
POST-CONTRACT: Schedules the supplied log message for interpreter-defined handling.
-}
log :: (HasCallStack) => AppLogMsg -> ScenarioProgram script serviceLib ()
log msg = FC.liftF $ ScenarioLogMsg callStack msg ()

{- | Emit an informational application log message.
PRE-CONTRACT: None
POST-CONTRACT: Logs the supplied message at the App severity level.
-}
logInfo :: (HasCallStack) => Text -> ScenarioProgram script serviceLib ()
logInfo msg = FC.liftF $ ScenarioLogMsg callStack (AppLogMsg msg) ()

{- | Emit a warning-level application log message.
PRE-CONTRACT: None
POST-CONTRACT: Logs the supplied message at the warning severity level.
-}
logWarn :: (HasCallStack) => Text -> ScenarioProgram script serviceLib ()
logWarn msg = FC.liftF $ ScenarioLogMsg callStack (WarnLogMsg msg) ()

{- | Emit an error-level application log message.
PRE-CONTRACT: None
POST-CONTRACT: Logs the supplied message at the error severity level.
-}
logError :: (HasCallStack) => Text -> ScenarioProgram script serviceLib ()
logError msg = FC.liftF $ ScenarioLogMsg callStack (ErrorLogMsg msg) ()

{- | Emit a sensitive log message intended for debug-only sinks.
PRE-CONTRACT: None
POST-CONTRACT: Logs the supplied message using the sensitive log variant.
-}
logSensitive :: (HasCallStack) => Text -> ScenarioProgram script serviceLib ()
logSensitive msg = FC.liftF $ ScenarioLogMsg callStack (SensitiveLogMsg msg) ()

{- | Read the interpreter-provided extra context map.
PRE-CONTRACT: None
POST-CONTRACT: Returns the complete extra-context map exposed by the active interpreter.
-}
getExtraContext :: ScenarioProgram script serviceLib (HashMap Text Text)
getExtraContext = FC.liftF $ GetExtraContext id

{- | Look up a single key inside the interpreter extra-context map.
PRE-CONTRACT: None
POST-CONTRACT: Returns Just value when the requested key exists and Nothing otherwise.
-}
readFromExtraContext :: Text -> ScenarioProgram script serviceLib (Maybe Text)
readFromExtraContext key = FC.liftF $ GetExtraContext (HM.lookup key)

{- | Interpret an extra-context key as a boolean feature flag.
PRE-CONTRACT: None
POST-CONTRACT: Returns True only when the stored value is exactly "true"; otherwise returns False.
-}
getFeatureFlag :: Text -> ScenarioProgram script serviceLib Bool
getFeatureFlag key = FC.liftF $ GetExtraContext (isEnabled . HM.lookup key)
 where
  isEnabled r = case r of
    Nothing -> False
    Just v -> v == "true"

{- | Run a control program with additional logging context entries.
PRE-CONTRACT: None
POST-CONTRACT: The supplied action observes the merged log context chosen by the interpreter.
-}
withLogContext :: [(Text, Text)] -> ScenarioProgram script serviceLib a -> ScenarioProgram script serviceLib a
withLogContext values act = FC.liftF $ ScenarioWithLogCtx values act id

{- | Add a single showable value to the logging context for the duration of an action.
PRE-CONTRACT: None
POST-CONTRACT: The supplied action runs with one additional key/value log entry.
-}
withLogEntry :: (Show a) => Text -> a -> ScenarioProgram script serviceLib b -> ScenarioProgram script serviceLib b
withLogEntry key value act = FC.liftF $ ScenarioWithLogCtx values act id
 where
  values = [(key, tshow value)]

{- | Add two showable values to the logging context for the duration of an action.
PRE-CONTRACT: None
POST-CONTRACT: The supplied action runs with both key/value log entries added to the context.
-}
with2LogEntries :: (Show a, Show b) => ((Text, a), (Text, b)) -> ScenarioProgram script serviceLib z -> ScenarioProgram script serviceLib z
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
runAsync :: ScenarioProgram script serviceLib () -> ScenarioProgram script serviceLib ()
runAsync act = FC.liftF $ RunAsync act ()

{- | Execute an action later: not before the delay has elapsed, on a worker of the async pool.
PRE-CONTRACT: In production the runTimerService + worker pool must be running.
POST-CONTRACT: Returns immediately; the action runs exactly once, not before the deadline; equal deadlines run FIFO in registration order; delay ≤ 0 means immediate.
-}
runAsyncAfter :: NominalDiffTime -> ScenarioProgram script serviceLib () -> ScenarioProgram script serviceLib ()
runAsyncAfter delay act = FC.liftF $ RunAsyncAfter delay act ()

{- | Escape hatch that runs an arbitrary 'IO' action inside a scenario.

This is a FALLBACK for cases where none of the structured effects fit:
'LazyCircus.Scene.DB', 'LazyCircus.Scene.Telegram', 'LazyCircus.Scene.AI',
'LazyCircus.Scene.Mail', 'LazyCircus.Scene.HTTP', or a registered service
('callService'). Before reaching for this, consider whether the operation
deserves its own scene language or a 'ServiceHandler'.

WARNING: the supplied 'IO' is executed for real by every interpreter,
including the test performer, so it CANNOT be mocked or captured the way
Telegram/AI/Mail sends are. Anything run through here is opaque to the
test infrastructure, observability, and automatic timing ('timedAndLog').
Pre-allocate a structured effect whenever the side effect is worth testing.

PRE-CONTRACT: None
POST-CONTRACT: The returned program yields the result of the supplied 'IO'
action, executed through the active interpreter.
-}
runArbitraryIO :: IO a -> ScenarioProgram script serviceLib a
runArbitraryIO io = FC.liftF $ RunArbitraryIO io id

{- | Enable LogLangF smart constructors to work directly in ScenarioProgram.
Maps LogLangF operations to the unified Scenario constructors.
-}
callService :: (S.IsInServiceLib serviceLib request response) => request -> ScenarioProgram script serviceLib response
callService req = FC.liftF $ CallService req id

instance HasLogLang (Scenario script serviceLib) (ScenarioProgram script serviceLib) where
  embedLog (LogMsg cs msg next) = ScenarioLogMsg cs msg next
  embedLog (WithLogCtx values prog next) = ScenarioWithLogCtx values prog next

class KnownHowToEval script m where
  evalSubScript :: script a -> m a