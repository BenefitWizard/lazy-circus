{-# LANGUAGE RankNTypes #-}

--   PURPOSE: Run the scheduled control-action worker loop and provide a helper that enqueues control programs for asynchronous execution.
--   SCOPE: Startup worker loop that drains the shared scheduled-actions queue with a supplied runner and the helper that writes new control programs into that queue.
--   DEPENDS: M-LIB-APP-LOG, M-LIB-CONTROL, M-LIB-INTERPRETER-COMMON

-- | Runtime helpers for draining and filling the scheduled async action queue.
module LazyCircus.AsyncWorker (
    runAsyncWorker,
    scheduleAsyncAction,
) where

import LazyCircus.AsyncWorker.Types
import LazyCircus.Scenario
import RIO

-- | Drain the scheduled action queue and execute each action with the supplied runtime runner.
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

-- | Enqueue a control program for later execution by the async worker loop.
scheduleAsyncAction :: (HasScheduledActions sc sl env, MonadIO m, MonadReader env m) => ScenarioProgram sc sl () -> m ()
scheduleAsyncAction action = do
    actionsQueue <- view scheduledActionsL
    atomically $ writeTQueue actionsQueue action
