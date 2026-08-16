{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | hspec coverage for 'LazyCircus.AsyncWorker.runAsyncWorkerPool' concurrency semantics:
-- pool sizing, zero-clamping, error isolation, and cancellation cascade.
module AsyncWorkerPoolSpec (spec) where

import Control.Concurrent.STM (retry)
import Control.Monad.Free.Church qualified as FC
import LazyCircus.AsyncWorker (runAsyncWorkerPool)
import LazyCircus.AsyncWorker.Types (HasScheduledActions (..), ScheduledActions)
import LazyCircus.Scenario (Scenario (..), ScenarioProgram, runArbitraryIO)
import RIO
import RIO.Text qualified as Text
import Test.Hspec

-- | Generous upper bound for one pool scenario, tolerating slow CI machines.
tenSeconds :: Int
tenSeconds = 10 * 1000000

-- | Upper bound for auxiliary waits (worker startup, parent-thread termination).
fiveSeconds :: Int
fiveSeconds = 5 * 1000000

-- | Marker exception used to make one pool task fail deterministically.
data AsyncWorkerPoolBoom = AsyncWorkerPoolBoom
    deriving (Show)

-- | Ordinary exception so the worker's 'tryAny' captures it.
instance Exception AsyncWorkerPoolBoom

-- | Phantom script tag for control programs whose only instruction is 'runArbitraryIO'.
data PoolTaskScript a

-- | Control programs used as scheduled tasks in this spec.
type PoolTask = ScenarioProgram PoolTaskScript () ()

-- | Minimal environment for pool tests: the shared scheduled-actions queue and a log function.
data PoolEnv = PoolEnv
    { poolQueue :: ScheduledActions PoolTaskScript () -- ^ shared queue the worker pool drains
    , poolLogFunc :: LogFunc -- ^ log function observed by worker clamp and error logging
    }

-- | Exposes the shared scheduled-actions queue to producers and workers.
instance HasScheduledActions PoolTaskScript () PoolEnv where
    scheduledActionsL = lens poolQueue (\env q -> env{poolQueue = q})

-- | Exposes the pool log function to RIO logging methods.
instance HasLogFunc PoolEnv where
    logFuncL = lens poolLogFunc (\env f -> env{poolLogFunc = f})

-- | Records messages emitted through a test 'LogFunc'.
newtype LogRecorder = LogRecorder (TQueue Text)

-- | Allocate an empty log recorder.
newLogRecorder :: IO LogRecorder
newLogRecorder = LogRecorder <$> newTQueueIO

-- | Build a 'LogFunc' that records the rendered text of every emitted message.
recordingLogFunc :: LogRecorder -> LogFunc
recordingLogFunc (LogRecorder logs) = mkLogFunc $ \_cs _src _lvl msg ->
    atomically $ writeTQueue logs (utf8BuilderToText msg)

-- | Wait up to roughly five seconds for a recorded message containing the substring.
-- PRE-CONTRACT: The recorder must come from 'newLogRecorder'.
-- POST-CONTRACT: Returns True as soon as a matching message is recorded, False only after the deadline passed.
waitForLogContaining :: LogRecorder -> Text -> IO Bool
waitForLogContaining (LogRecorder logs) needle = go (100 :: Int)
  where
    go :: Int -> IO Bool
    go attempts
        | attempts <= 0 = pure False
        | otherwise = do
            recorded <- atomically drainRecorded
            if any (Text.isInfixOf needle) recorded
                then pure True
                else threadDelay 50000 >> go (attempts - 1)

    -- | Destructively reads every currently queued message.
    drainRecorded :: STM [Text]
    drainRecorded = do
        isEmpty <- isEmptyTQueue logs
        if isEmpty then pure [] else (:) <$> readTQueue logs <*> drainRecorded

-- | Allocate a fresh environment with an empty queue and a recording log function, plus its recorder.
mkPoolEnv :: IO (PoolEnv, LogRecorder)
mkPoolEnv = do
    recorder <- newLogRecorder
    queue <- newTQueueIO
    pure (PoolEnv queue (recordingLogFunc recorder), recorder)

-- | Wrap an IO action into a scheduled pool task.
mkTask :: IO () -> PoolTask
mkTask = runArbitraryIO

-- | Interpret a pool task by executing only its 'runArbitraryIO' payload.
-- PRE-CONTRACT: Tasks are built with 'mkTask'; no other scenario instruction is supported.
-- POST-CONTRACT: Exceptions from the payload propagate to the caller, matching the production runner seam.
runPoolTask :: PoolTask -> RIO PoolEnv ()
runPoolTask = FC.iterM step
  where
    step (RunArbitraryIO io next) = next =<< liftIO io
    step _ = error "AsyncWorkerPoolSpec supports only runArbitraryIO tasks"

-- | Run a probe while a worker pool of the requested size drains the environment queue.
-- PRE-CONTRACT: The probe enqueues its own tasks; the pool size is the value under test.
-- POST-CONTRACT: The pool is cancelled and reaped before returning, even when the probe throws or times out.
withWorkerPool :: Word -> PoolEnv -> IO a -> IO a
withWorkerPool size env probe =
    bracket
        (async (runRIO env (runAsyncWorkerPool size runPoolTask)))
        (\pool -> cancel pool >> void (waitCatch pool))
        (const probe)

spec :: Spec
spec = describe "AsyncWorkerPool" $ do
    it "runs at least the requested number of workers concurrently" $ do
        (env, _) <- mkPoolEnv
        let k = 4 :: Int
        arrived <- newTVarIO (0 :: Int)
        let barrierTask = mkTask $ do
                atomically $ modifyTVar' arrived (+ 1)
                atomically $ readTVar arrived >>= \c -> when (c < k) retry
        mPassed <- timeout tenSeconds $
            withWorkerPool 4 env $ do
                atomically $ replicateM_ k $ writeTQueue (poolQueue env) barrierTask
                atomically $ readTVar arrived >>= \c -> when (c < k) retry
        mPassed `shouldSatisfy` isJust
        finalCount <- readTVarIO arrived
        finalCount `shouldBe` k

    it "clamps a zero pool size to one worker and still drains the queue" $ do
        (env, recorder) <- mkPoolEnv
        gate <- newEmptyTMVarIO
        done <- newEmptyTMVarIO
        let firstTask = mkTask $ atomically $ putTMVar gate ()
            secondTask = mkTask $ atomically $ readTMVar gate >> putTMVar done ()
        mDone <- timeout tenSeconds $
            withWorkerPool 0 env $ do
                atomically $ writeTQueue (poolQueue env) firstTask
                atomically $ writeTQueue (poolQueue env) secondTask
                atomically $ readTMVar done
        mDone `shouldSatisfy` isJust
        clampLogged <- waitForLogContaining recorder "Async worker pool size is 0, clamping to 1 worker"
        clampLogged `shouldBe` True

    it "isolates a failing action, logs it, and keeps draining the queue" $ do
        (env, recorder) <- mkPoolEnv
        done <- newEmptyTMVarIO
        let failingTask = mkTask $ throwIO AsyncWorkerPoolBoom
            finishingTask = mkTask $ atomically $ putTMVar done ()
        mDone <- timeout tenSeconds $
            withWorkerPool 1 env $ do
                atomically $ writeTQueue (poolQueue env) failingTask
                atomically $ writeTQueue (poolQueue env) finishingTask
                atomically $ readTMVar done
        mDone `shouldSatisfy` isJust
        failureLogged <- waitForLogContaining recorder "Async worker action failed:"
        failureLogged `shouldBe` True

    it "stops all workers when the parent thread is cancelled" $ do
        (env, _) <- mkPoolEnv
        started <- newTVarIO (0 :: Int)
        sentinelConsumed <- newTVarIO False
        blockGate <- newEmptyTMVarIO
        let blockerTask = mkTask $ do
                atomically $ modifyTVar' started (+ 1)
                atomically $ readTMVar blockGate
            sentinelTask = mkTask $ atomically $ writeTVar sentinelConsumed True
        parent <- async (runRIO env (runAsyncWorkerPool 2 runPoolTask))
        atomically $ writeTQueue (poolQueue env) blockerTask
        atomically $ writeTQueue (poolQueue env) blockerTask
        mStarted <- timeout fiveSeconds $ atomically $ do
            c <- readTVar started
            when (c < 2) retry
        mStarted `shouldSatisfy` isJust
        cancel parent
        mStopped <- timeout fiveSeconds $ waitCatch parent
        mStopped `shouldSatisfy` isJust
        atomically $ writeTQueue (poolQueue env) sentinelTask
        threadDelay 1500000
        consumed <- readTVarIO sentinelConsumed
        consumed `shouldBe` False
