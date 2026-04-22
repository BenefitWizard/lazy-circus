-- | Shared async worker queue types and capabilities.
module LazyCircus.AsyncWorker.Types (
    ScheduledActions,
    HasScheduledActions (..),
) where

import LazyCircus.Scenario
import RIO

type ScheduledActions sc = TQueue (ScenarioProgram sc ())

class HasScheduledActions sc env where
    scheduledActionsL :: Lens' env (ScheduledActions sc)
