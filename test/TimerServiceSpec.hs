{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}

-- | hspec coverage for 'LazyCircus.AsyncWorker.runTimerService' deferred-execution semantics:
-- deadline ordering, re-arming on earlier insertions, FIFO order for equal deadlines, zero-delay
-- pickup, and direct delivery of deferred service casts (bypassing the async worker pool).
module TimerServiceSpec (spec) where

import Control.Concurrent.STM (retry)
import LazyCircus.App.Service
    ( HasFailbackValue (..)
    , HasServiceLib (..)
    , IsInServiceLib (..)
    , ServiceHandler
    , SomeServiceCast (..)
    , callService
    , castService
    , createServiceWithCast
    )
import LazyCircus.AsyncWorker (runAsyncWorker, runTimerService, scheduleAsyncAction, scheduleTimedAction, scheduleTimedServiceCast)
import LazyCircus.AsyncWorker.Types (HasScheduledActions (..), HasTimedActions (..), ScheduledActions, TimedActions (..))
import LazyCircus.Scenario (ScenarioPerformer (..), ScenarioProgram, castServiceAfter, run, runAsyncAfter, runArbitraryIO)
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
type TimerTask = ScenarioProgram TimerTaskScript FakeLib ()

-- | Request type of the fake service used to observe deferred cast delivery.
data FakeRequest = FakePing Text | FakeStuck
    deriving (Eq, Show)

-- | Response type of the fake service; produced only by the call path.
data FakeResponse = FakeAck Text
    deriving (Eq, Show)

-- | Calls are not exercised by this spec; the failback value exists to satisfy the worker.
instance HasFailbackValue FakeResponse where
    failbackValue = FakeAck "failback"

-- | One-entry service library: the fake service handler this spec observes.
data FakeLib = FakeLib
    { fakeLibService :: ServiceHandler FakeRequest FakeResponse -- ^ mailbox of the fake service
    }

-- | Dispatch mirrors the TH-generated wiring: calls and casts both go to the fake service.
instance IsInServiceLib FakeLib FakeRequest FakeResponse where
    callFromServiceLib lib req = callService (fakeLibService lib) req
    castFromServiceLib lib req = castService (fakeLibService lib) req

-- | Minimal environment for timer tests: the timed registry, the scheduled queue, the service
-- library, and a log function.
data TimerEnv = TimerEnv
    { timerTimedActions :: TimedActions TimerTaskScript FakeLib -- ^ registry the timer service drains
    , timerScheduledActions :: ScheduledActions TimerTaskScript FakeLib -- ^ queue the timer fills and the worker drains
    , timerServiceLib :: FakeLib             -- ^ service library the timer delivers deferred casts through
    , timerServiceWorker :: IO ()            -- ^ unforked fake-service worker loop
    , timerLogFunc :: LogFunc                -- ^ log function observed by the worker loop
    }

-- | Exposes the timed registry to the timer service and 'scheduleTimedAction'.
instance HasTimedActions TimerTaskScript FakeLib TimerEnv where
    timedActionsL = lens timerTimedActions (\env t -> env{timerTimedActions = t})

-- | Exposes the scheduled queue to producers, the timer service, and the worker.
instance HasScheduledActions TimerTaskScript FakeLib TimerEnv where
    scheduledActionsL = lens timerScheduledActions (\env q -> env{timerScheduledActions = q})

-- | Exposes the service library to the timer service's deferred-cast delivery.
instance HasServiceLib TimerEnv FakeLib where
    serviceLibL = lens timerServiceLib (\env lib -> env{timerServiceLib = lib})

-- | Exposes the log function to RIO logging methods.
instance HasLogFunc TimerEnv where
    logFuncL = lens timerLogFunc (\env f -> env{timerLogFunc = f})

-- | Interpreter seam mirroring the production wiring: 'runAsyncAfter'' registers into the timed
-- registry, 'runAsync'' enqueues into the scheduled queue, and 'castServiceAfter'' registers a
-- deferred cast into the same registry.
-- PRE-CONTRACT: Programs use only 'runAsyncAfter', 'castServiceAfter', and 'runArbitraryIO' instructions.
-- POST-CONTRACT: Deferred programs land in the same registry and queue the timer service and worker observe; deferred casts land in the registry the timer service delivers from.
instance ScenarioPerformer TimerTaskScript FakeLib (RIO TimerEnv) where
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
    castService' = error "TimerServiceSpec tasks never cast to services"
    -- @TimerTaskScript is applied explicitly: it is phantom in 'SomeServiceCast',
    -- so inference cannot otherwise connect the call to this instance context.
    castServiceAfter' delay req = scheduleTimedServiceCast @TimerTaskScript delay (SomeServiceCast req)

-- | Allocate a fresh environment with an empty registry, an empty queue, and the fake service
-- whose cast handler appends @cast:\<label\>@ markers into the shared journal (returning the
-- worker action unforked). The call handler is never exercised by this spec.
-- POST-CONTRACT: The returned journal is shared by the scheduled scenario tasks and the fake-service cast handler.
mkTimerEnv :: IO (TimerEnv, TVar [Text])
mkTimerEnv = mkTimerEnvWith Nothing

-- | Like 'mkTimerEnv' but with a stuck cast handler: when 'Just' a barrier is supplied,
-- the handler for 'FakeStuck' blocks on it forever, simulating a wedged service worker.
mkTimerEnvWith :: Maybe (MVar ()) -> IO (TimerEnv, TVar [Text])
mkTimerEnvWith stuckBarrier = do
    entries <- newTVarIO []
    nextSeq <- newTVarIO 0
    queue <- newTQueueIO
    journal <- newTVarIO []
    (handler, workerAction) <- createServiceWithCast (fakeCastHandler journal) (fakeCallHandler journal)
    let env =
            TimerEnv
                { timerTimedActions = TimedActions entries nextSeq
                , timerScheduledActions = queue
                , timerServiceLib = FakeLib handler
                , timerServiceWorker = workerAction
                , timerLogFunc = mkLogFunc $ \_ _ _ _ -> pure ()
                }
    pure (env, journal)
  where
    -- | Records every delivered cast into the journal; 'FakeStuck' blocks on the barrier.
    fakeCastHandler journal req = case req of
        FakePing label -> atomically $ modifyTVar' journal (++ ["cast:" <> label])
        FakeStuck -> traverse_ takeMVar stuckBarrier
    -- | Records the call and acknowledges; this spec never triggers it.
    fakeCallHandler journal req = do
        atomically $ modifyTVar' journal (++ ["call:" <> tshow req])
        pure (FakeAck "ok")

-- | Build a deferred task that appends its label to the shared journal when a worker executes it.
mkLabelTask :: TVar [Text] -> Text -> TimerTask
mkLabelTask journal label = runArbitraryIO $ atomically $ modifyTVar' journal (++ [label])

-- | Schedule one deferred task through the real 'runAsyncAfter' instruction interpreted by the mini performer.
scheduleViaRunAsyncAfter :: TimerEnv -> NominalDiffTime -> TimerTask -> IO ()
scheduleViaRunAsyncAfter env delay task = runRIO env $ run (runAsyncAfter delay task)

-- | Schedule one deferred cast through the real 'castServiceAfter' instruction interpreted by the mini performer.
scheduleViaCastServiceAfter :: TimerEnv -> NominalDiffTime -> FakeRequest -> IO ()
scheduleViaCastServiceAfter env delay req =
    runRIO env $ run (castServiceAfter delay req :: ScenarioProgram TimerTaskScript FakeLib ())

-- | Block until the journal holds at least the requested number of labels, then return its contents.
-- PRE-CONTRACT: The journal comes from 'mkTimerEnv'.
-- POST-CONTRACT: The returned list reflects task-execution order and has at least the requested length.
awaitJournal :: TVar [Text] -> Int -> STM [Text]
awaitJournal journal expected = do
    entries <- readTVar journal
    when (length entries < expected) retry
    pure entries

-- | Run a probe while the real timer service, one async worker, and the fake-service worker drain
-- the shared environment.
-- PRE-CONTRACT: The probe schedules its own tasks via 'scheduleViaRunAsyncAfter' or 'scheduleViaCastServiceAfter' on the same environment.
-- POST-CONTRACT: All threads are cancelled and reaped before returning, even when the probe throws or times out.
withTimerRuntime :: TimerEnv -> IO a -> IO a
withTimerRuntime env probe =
    bracket
        ( (,,)
            <$> async (runRIO env (runTimerService @TimerTaskScript @FakeLib))
            <*> async (runRIO env (runAsyncWorker (run @TimerTaskScript @FakeLib)))
            <*> async (timerServiceWorker env)
        )
        ( \(timerThread, workerThread, serviceThread) -> do
            cancel timerThread
            cancel workerThread
            cancel serviceThread
            void (waitCatch timerThread)
            void (waitCatch workerThread)
            void (waitCatch serviceThread)
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

    it "delivers a deferred cast to its service when the deadline fires" $ do
        (env, journal) <- mkTimerEnv
        mJournal <-
            timeout twoSeconds $ withTimerRuntime env $ do
                scheduleViaCastServiceAfter env 0.05 (FakePing "A")
                atomically (awaitJournal journal 1)
        mJournal `shouldBe` Just ["cast:A"]

    it "delivers deferred casts and scenario tasks in deadline order" $ do
        (env, journal) <- mkTimerEnv
        let taskS = mkLabelTask journal "S"
        mJournal <-
            timeout twoSeconds $ withTimerRuntime env $ do
                scheduleViaRunAsyncAfter env 0.1 taskS
                scheduleViaCastServiceAfter env 0.03 (FakePing "C")
                atomically (awaitJournal journal 2)
        mJournal `shouldBe` Just ["cast:C", "S"]

    it "keeps firing later deadlines while a cast handler is stuck" $ do
        barrier <- newEmptyMVar
        (env, journal) <- mkTimerEnvWith (Just barrier)
        mJournal <-
            timeout twoSeconds $ withTimerRuntime env $ do
                scheduleViaCastServiceAfter env 0.03 FakeStuck
                scheduleViaRunAsyncAfter env 0.1 (mkLabelTask journal "later")
                atomically (awaitJournal journal 1)
        -- The stuck cast's mailbox write never blocks the timer loop, so the
        -- later scenario task still fires; the stuck cast handler never records.
        mJournal `shouldBe` Just ["later"]

    it "fires a zero-delay cast immediately" $ do
        (env, journal) <- mkTimerEnv
        mJournal <-
            timeout twoSeconds $ withTimerRuntime env $ do
                scheduleViaCastServiceAfter env 0 (FakePing "zero")
                atomically (awaitJournal journal 1)
        mJournal `shouldBe` Just ["cast:zero"]
