{-# LANGUAGE FunctionalDependencies #-}

-- | Shared async worker queue types and capabilities.
module LazyCircus.AsyncWorker.Types (
    ScheduledActions,
    HasScheduledActions (..),
    TimedAction (..),
    TimedActions (..),
    HasTimedActions (..),
) where

import LazyCircus.Scenario
import RIO
import RIO.Time (UTCTime)

type ScheduledActions sc sl = TQueue (ScenarioProgram sc sl ())

-- class HasScheduledActions sc sl env where
--     scheduledActionsL :: Lens' env (ScheduledActions sc sl)

-- | Satisfies HasScheduledActions for Script by delegating to the asyncTasks field.
class HasScheduledActions script sl env | env -> sl where
    scheduledActionsL :: Lens' env (ScheduledActions script sl)

-- | One deferred action: a program plus its absolute deadline and registration order.
data TimedAction script sl = TimedAction
    { taDeadline :: UTCTime                        -- ^ absolute deadline (now + delay at registration)
    , taSeq      :: Word                           -- ^ monotonic counter giving FIFO order for equal deadlines
    , taProgram  :: ScenarioProgram script sl ()   -- ^ the deferred program to run when the deadline fires
    }

-- | Registry of deferred actions: a sorted list of entries plus a sequence counter.
--
-- Invariants:
--   1. 'timedActionsEntries' is always kept sorted by @(taDeadline, taSeq)@ via @insertBy@.
--   2. 'taSeq' values taken from 'timedActionsNextSeq' are strictly increasing.
data TimedActions script sl = TimedActions
    { timedActionsEntries :: TVar [TimedAction script sl] -- ^ deferred actions, always kept sorted by (taDeadline, taSeq)
    , timedActionsNextSeq :: TVar Word                    -- ^ separate TVar (not inside the list) so concurrent inserts don't race on numbering
    }

-- | Satisfies HasTimedActions for Script by delegating to the timedActions field.
class HasTimedActions script sl env | env -> sl where
    timedActionsL :: Lens' env (TimedActions script sl)