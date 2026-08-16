{-# LANGUAGE RankNTypes #-}

--   PURPOSE: Run the scheduled control-action worker loop and provide a helper that enqueues control programs for asynchronous execution.
--   SCOPE: Startup worker loop that drains the shared scheduled-actions queue with a supplied runner, a fixed-size worker pool running that loop concurrently over the shared queue, and the helper that writes new control programs into that queue.
--   DEPENDS: M-LIB-APP-LOG, M-LIB-CONTROL, M-LIB-INTERPRETER-COMMON

-- | Runtime helpers for draining and filling the scheduled async action queue.
module LazyCircus.AsyncWorker (
    runAsyncWorker,
    runAsyncWorkerPool,
    scheduleAsyncAction,
) where

import LazyCircus.AsyncWorker.Types
import LazyCircus.Scenario
import RIO

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
