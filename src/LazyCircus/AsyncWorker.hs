{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RankNTypes #-}

--   PURPOSE: Run the scheduled control-action worker loop and the timer service, and provide helpers that enqueue control programs for immediate or deferred asynchronous execution.
--   SCOPE: Startup worker loop that drains the shared scheduled-actions queue with a supplied runner, a fixed-size worker pool running that loop concurrently over the shared queue, the timer loop that moves due deferred programs from the timed-actions registry into that queue, and the helpers that write new control programs into the queue or the registry.
--   DEPENDS: M-LIB-APP-LOG, M-LIB-CONTROL, M-LIB-INTERPRETER-COMMON

-- | Runtime helpers for draining and filling the scheduled async action queue and the timed-action registry.
module LazyCircus.AsyncWorker (
    runAsyncWorker,
    runAsyncWorkerPool,
    scheduleAsyncAction,
    scheduleTimedAction,
    runTimerService,
) where

import Control.Concurrent.STM (retry)
import Data.List (insertBy)
import Data.Ord (comparing)
import LazyCircus.AsyncWorker.Types
import LazyCircus.Scenario
import RIO
import RIO.Time (NominalDiffTime, addUTCTime, diffUTCTime, getCurrentTime)

-- | Drain the scheduled action queue and execute each action with the supplied runtime runner.
-- PRE-CONTRACT: Must run in a dedicated thread — it blocks forever draining the queue.
-- POST-CONTRACT: A failing action is logged, not rethrown; the loop keeps draining the queue.
runAsyncWorker :: (HasScheduledActions sc sl env, HasLogFunc env) => (ScenarioProgram sc sl () -> RIO env ()) -> RIO env ()
runAsyncWorker runScenario = do
    actionsQueue <- view scheduledActionsL
    forever $ do
        action <- atomically $ readTQueue actionsQueue
        result <- tryAny $ runScenario action
        case result of
            Left e ->
                let
                    err = "Async worker action failed: " <> displayShow e
                 in
                    RIO.logError err
            Right _ -> pure ()

-- | Upper bound on the async worker pool size; larger requests are clamped with a warning.
maxPoolSize :: Int
maxPoolSize = 1024

-- | Run the async worker loop as a pool of n concurrent workers over the shared scheduled-actions queue.
-- All workers compete on the same 'TQueue', so scheduled actions are work-stolen via competing 'readTQueue'.
-- PRE-CONTRACT: All producers and workers must share the single scheduled-actions queue from the environment ('HasScheduledActions').
-- POST-CONTRACT: Blocks forever draining the queue — must be run in a dedicated thread; n = 0 is clamped to 1 and n > 1024 to 1024, each with a warning; cancelling or killing the calling thread stops all workers (unliftio's 'mapConcurrently_' kills and waits for all children when the parent dies).
runAsyncWorkerPool :: (HasScheduledActions sc sl env, HasLogFunc env) => Word -> (ScenarioProgram sc sl () -> RIO env ()) -> RIO env ()
runAsyncWorkerPool n runScenario = do
    poolSize <- clampPoolSize n
    mapConcurrently_ (const (runAsyncWorker runScenario)) (replicate poolSize ())
  where
    -- | Clamps the requested pool size into the safe range [1, maxPoolSize] with a warning on each clamp,
    -- so the queue always has at least one drainer and the 'Word'-to-'Int' conversion never wraps.
    clampPoolSize :: HasLogFunc env => Word -> RIO env Int
    clampPoolSize 0 = do
        RIO.logWarn "Async worker pool size is 0, clamping to 1 worker"
        pure 1
    clampPoolSize k
        | k > fromIntegral maxPoolSize = do
            RIO.logWarn
                (  "Async worker pool size is above the supported maximum of "
                <> displayShow maxPoolSize
                <> ", clamping to "
                <> displayShow maxPoolSize
                <> " workers"
                )
            pure maxPoolSize
        | otherwise = pure (fromIntegral k)

-- | Enqueue a control program for later execution by the async worker loop.
scheduleAsyncAction :: (HasScheduledActions sc sl env, MonadIO m, MonadReader env m) => ScenarioProgram sc sl () -> m ()
scheduleAsyncAction action = do
    actionsQueue <- view scheduledActionsL
    atomically $ writeTQueue actionsQueue action

-- | Register a control program for deferred execution by the timer service after the given delay.
-- PRE-CONTRACT: The production runtime must run 'runTimerService' plus the async worker pool, otherwise the program is registered but never executed.
-- POST-CONTRACT: Returns immediately; the program is executed exactly once, no earlier than @delay@ from this call; equal deadlines fire in registration (FIFO) order; @delay <= 0@ is picked up immediately (equivalent to 'scheduleAsyncAction').
scheduleTimedAction :: (HasTimedActions sc sl env, MonadIO m, MonadReader env m) => NominalDiffTime -> ScenarioProgram sc sl () -> m ()
scheduleTimedAction delay program = do
    timedActions <- view timedActionsL
    now <- getCurrentTime
    atomically $ do
        nextSeq <- readTVar (timedActionsNextSeq timedActions)
        writeTVar (timedActionsNextSeq timedActions) (nextSeq + 1)
        entries <- readTVar (timedActionsEntries timedActions)
        let
            entry =
                TimedAction
                    { taDeadline = addUTCTime delay now
                    , taSeq = nextSeq
                    , taProgram = program
                    }
            sorted = insertBy (comparing (\e -> (taDeadline e, taSeq e))) entry entries
         in
            writeTVar (timedActionsEntries timedActions) sorted

-- | Timer loop that moves due deferred programs from the timed-actions registry into the scheduled queue.
-- PRE-CONTRACT: Must run in a dedicated thread — it blocks forever; the async worker pool must be running to execute the moved programs.
-- POST-CONTRACT: A program is moved to the scheduled queue no earlier than its deadline; popping the expired prefix and enqueueing its programs happen in one STM transaction, so actions are neither lost nor duplicated; equal deadlines are drained in FIFO (seq) order; actions still in the registry on cancellation are dropped silently.
runTimerService :: forall sc sl env. (HasTimedActions sc sl env, HasScheduledActions sc sl env) => RIO env ()
runTimerService = do
    timedActions <- view (timedActionsL @sc)
    actionsQueue <- view (scheduledActionsL @sc)
    -- Deliberately no tryAny around the loop: nothing inside throws user exceptions (pure STM plus registerDelay), so an escaping exception can only be cancellation and must kill the service.
    forever $ do
        armed <- atomically $ do
            entries <- readTVar (timedActionsEntries timedActions)
            case entries of
                [] -> retry
                (entry : _) -> pure entry
        now <- getCurrentTime
        let micros = max 0 (ceiling (realToFrac (diffUTCTime (taDeadline armed) now) * 1000000))
        timer <- registerDelay micros
        atomically $ do
            fired <- readTVar timer
            if fired
                then do
                    entries <- readTVar (timedActionsEntries timedActions)
                    let (expired, rest) = span (\e -> taDeadline e <= taDeadline armed) entries
                    mapM_ (writeTQueue actionsQueue . taProgram) expired
                    writeTVar (timedActionsEntries timedActions) rest
                else do
                    entries <- readTVar (timedActionsEntries timedActions)
                    case entries of
                        -- Re-arm check compares heads by taSeq only: equal deadlines must not falsely re-arm the timer.
                        (entry : _) | taSeq entry == taSeq armed -> retry
                        _ -> pure ()
