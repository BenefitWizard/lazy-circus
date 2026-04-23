{-# LANGUAGE FunctionalDependencies #-}

-- | Shared async worker queue types and capabilities.
module LazyCircus.AsyncWorker.Types (
    ScheduledActions,
    HasScheduledActions (..),
) where

import LazyCircus.Scenario
import RIO

type ScheduledActions sc sl = TQueue (ScenarioProgram sc sl ())

-- class HasScheduledActions sc sl env where
--     scheduledActionsL :: Lens' env (ScheduledActions sc sl)

-- | Satisfies HasScheduledActions for Script by delegating to the asyncTasks field.
class HasScheduledActions script sl env | env -> sl where
    scheduledActionsL :: Lens' env (ScheduledActions script sl)