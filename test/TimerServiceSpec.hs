{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}

-- | hspec coverage for 'LazyCircus.AsyncWorker.runTimerService' deferred-execution semantics:
-- deadline ordering, re-arming on earlier insertions, FIFO order for equal deadlines, and zero-delay pickup.
module TimerServiceSpec (spec) where

import Control.Concurrent.STM (retry)
import LazyCircus.AsyncWorker (runAsyncWorker, runTimerService, scheduleAsyncAction, scheduleTimedAction)
import LazyCircus.AsyncWorker.Types (HasScheduledActions (..), HasTimedActions (..), ScheduledActions, TimedActions (..))
import LazyCircus.Scenario (ScenarioPerformer (..), ScenarioProgram, run, runAsyncAfter, runArbitraryIO)
import RIO
import RIO.Time (NominalDiffTime, getCurrentTime)
import Test.Hspec

-- | Upper bound for one timer scenario, tolerating slow CI machines.
twoSeconds :: Int
twoSeconds = 2 * 1000000

-- | Pause between scheduling calls when a case must let the timer service arm first.
armingPause :: Int
armingPause = 20000

-- | Phantom script tag for programs whose only instructions are 'runAsyncAfter' and 'runArbitraryIO'.
data TimerTaskScript a

-- | Control programs used as deferred tasks in this spec.
type TimerTask = ScenarioProgram TimerTaskScript () ()

-- | Minimal environment for timer tests: the timed registry, the scheduled queue, and a log function.
data TimerEnv = TimerEnv
    { timerTimedActions :: TimedActions TimerTaskScript () -- ^ registry the timer service drains
    , timerScheduledActions :: ScheduledActions TimerTaskScript () -- ^ queue the timer fills and the worker drains
    , timerLogFunc :: LogFunc -- ^ log function observed by the worker loop
    }

-- | Exposes the timed registry to the timer service and 'scheduleTimedAction'.
instance HasTimedActions TimerTaskScript () TimerEnv where
    timedActionsL = lens timerTimedActions (\env t -> env{timerTimedActions = t})

-- | Exposes the scheduled queue to producers, the timer service, and the worker.
instance HasScheduledActions TimerTaskScript () TimerEnv where
    scheduledActionsL = lens timerScheduledActions (\env q -> env{timerScheduledActions = q})

-- | Exposes the log function to RIO logging methods.
instance HasLogFunc TimerEnv where
    logFuncL = lens timerLogFunc (\env f -> env{timerLogFunc = f})

-- | Interpreter seam mirroring the production wiring: 'runAsyncAfter'' registers into the timed
-- registry and 'runAsync'' enqueues into the scheduled queue.
-- PRE-CONTRACT: Programs use only 'runAsyncAfter' and 'runArbitraryIO' instructions.
-- POST-CONTRACT: Deferred programs land in the same registry and queue the timer service and worker observe.
instance ScenarioPerformer TimerTaskScript () (RIO TimerEnv) where
    onEvalScript = error "TimerServiceSpec defines no scene scripts"
    throw' = throwIO
    runSafely' = error "TimerServiceSpec tasks never use runSafely"
    getDateTime' = liftIO getCurrentTime
    log' _ _ = pure ()
    getExtraContext' = pure mempty
    withLogContext' _ act = run act
    runAsync' = scheduleAsyncAction
    runAsyncAfter' = scheduleTimedAction
    runArbitraryIO' = liftIO
    callService' = error "TimerServiceSpec tasks never call services"

-- | Allocate a fresh environment with an empty registry, an empty queue, a discarding log function,
-- plus the shared journal the scheduled tasks append to.
mkTimerEnv :: IO (TimerEnv, TVar [Text])
mkTimerEnv = do
    entries <- newTVarIO []
    nextSeq <- newTVarIO 0
    queue <- newTQueueIO
    journal <- newTVarIO []
    pure (TimerEnv (TimedActions entries nextSeq) queue (mkLogFunc $ \_ _ _ _ -> pure ()), journal)

-- | Build a deferred task that appends its label to the shared journal when a worker executes it.
mkLabelTask :: TVar [Text] -> Text -> TimerTask
mkLabelTask journal label = runArbitraryIO $ atomically $ modifyTVar' journal (++ [label])

-- | Schedule one deferred task through the real 'runAsyncAfter' instruction interpreted by the mini performer.
scheduleViaRunAsyncAfter :: TimerEnv -> NominalDiffTime -> TimerTask -> IO ()
scheduleViaRunAsyncAfter env delay task = runRIO env $ run (runAsyncAfter delay task)

-- | Block until the journal holds at least the requested number of labels, then return its contents.
-- PRE-CONTRACT: The journal comes from 'mkTimerEnv'.
-- POST-CONTRACT: The returned list reflects task-execution order and has at least the requested length.
awaitJournal :: TVar [Text] -> Int -> STM [Text]
awaitJournal journal expected = do
    entries <- readTVar journal
    when (length entries < expected) retry
    pure entries

-- | Run a probe while the real timer service and one async worker drain the shared environment.
-- PRE-CONTRACT: The probe schedules its own tasks via 'scheduleViaRunAsyncAfter' on the same environment.
-- POST-CONTRACT: Both threads are cancelled and reaped before returning, even when the probe throws or times out.
withTimerRuntime :: TimerEnv -> IO a -> IO a
withTimerRuntime env probe =
    bracket
        ( (,)
            <$> async (runRIO env (runTimerService @TimerTaskScript @()))
            <*> async (runRIO env (runAsyncWorker (run @TimerTaskScript @())))
        )
        ( \(timerThread, workerThread) -> do
            cancel timerThread
            cancel workerThread
            void (waitCatch timerThread)
            void (waitCatch workerThread)
        )
        (const probe)

spec :: Spec
spec = describe "TimerService" $ do
    it "executes in deadline order when a later-registered action has an earlier deadline" $ do
        (env, journal) <- mkTimerEnv
        let taskA = mkLabelTask journal "A"
            taskB = mkLabelTask journal "B"
        mJournal <-
            timeout twoSeconds $ withTimerRuntime env $ do
                scheduleViaRunAsyncAfter env 0.1 taskA
                scheduleViaRunAsyncAfter env 0.03 taskB
                atomically (awaitJournal journal 2)
        mJournal `shouldBe` Just ["B", "A"]

    it "re-arms when an earlier deadline is inserted after the timer armed" $ do
        (env, journal) <- mkTimerEnv
        let taskA = mkLabelTask journal "A"
            taskB = mkLabelTask journal "B"
        mJournal <-
            timeout twoSeconds $ withTimerRuntime env $ do
                scheduleViaRunAsyncAfter env 0.15 taskA
                threadDelay armingPause
                scheduleViaRunAsyncAfter env 0.03 taskB
                atomically (awaitJournal journal 2)
        mJournal `shouldBe` Just ["B", "A"]

    it "runs equal deadlines FIFO in registration order" $ do
        (env, journal) <- mkTimerEnv
        let task1 = mkLabelTask journal "1"
            task2 = mkLabelTask journal "2"
            task3 = mkLabelTask journal "3"
        mJournal <-
            timeout twoSeconds $ withTimerRuntime env $ do
                scheduleViaRunAsyncAfter env 0.05 task1
                scheduleViaRunAsyncAfter env 0.05 task2
                scheduleViaRunAsyncAfter env 0.05 task3
                atomically (awaitJournal journal 3)
        mJournal `shouldBe` Just ["1", "2", "3"]

    it "fires a zero delay immediately" $ do
        (env, journal) <- mkTimerEnv
        let taskA = mkLabelTask journal "A"
        mJournal <-
            timeout twoSeconds $ withTimerRuntime env $ do
                scheduleViaRunAsyncAfter env 0 taskA
                atomically (awaitJournal journal 1)
        mJournal `shouldBe` Just ["A"]
