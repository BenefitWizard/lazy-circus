{-# LANGUAGE OverloadedStrings #-}

-- | Hspec coverage for logging-context helpers and queue emission.
module LogSpec (spec) where

import GHC.Stack (callStack)
import LazyCircus.App.Default (DefaultApp (..), logAppFromDefaultApp)
import LazyCircus.App.Log
    ( AppLogMsg (..)
    , AppLogMsgWithContext (AppLogMsgWithContext, logMsg)
    , HasLogQueue (..)
    , HasLoggingContext (..)
    , LoggingContext (..)
    , LogQueue
    , putInLoggingContext
    , sublangLog
    )
import LazyCircus.App.Log qualified as Log
import RIO
import RIO.Map qualified as M
import Test.Hspec
import Unsafe.Coerce (unsafeCoerce)

-- | A no-op LogFunc for tests that do not need RIO's standard logging.
noopLogFunc :: LogFunc
noopLogFunc = mkLogFunc $ \_cs _src _lvl _msg -> pure ()

-- | Test environment with a log queue and logging context, no GLogFunc.
data TestLogEnv = TestLogEnv
    { testLogQueue :: LogQueue
    , testLogContext :: LoggingContext
    }

instance HasLogQueue TestLogEnv where
    logQueueL = lens testLogQueue (\env queue -> env{testLogQueue = queue})

instance HasLoggingContext TestLogEnv where
    logContextL = lens testLogContext (\env ctx -> env{testLogContext = ctx})

mkEnv :: IO TestLogEnv
mkEnv = do
    queue <- newTQueueIO
    pure $ TestLogEnv queue mempty

readSingleLog :: LogQueue -> IO AppLogMsgWithContext
readSingleLog queue = atomically $ readTQueue queue

spec :: Spec
spec = do
    describe "putInLoggingContext" $ do
        it "adds new keys and lets inner values override outer ones" $ do
            let original = LogContext $ M.fromList [("aaa", "bbb"), ("ccc", "ddd")]
                updated = putInLoggingContext original [("aaa", "xxx"), ("eee", "fff")]
                expectedMap = M.fromList [("aaa", "xxx"), ("ccc", "ddd"), ("eee", "fff")]

            case updated of
                LogContext actualMap -> actualMap `shouldBe` expectedMap

    describe "sublangLog" $ do
        it "writes a contextualized message to the shared queue" $ do
            env <- mkEnv
            let envWithCtx = env{testLogContext = LogContext $ M.fromList [("request_id", "abc")]}

            runRIO envWithCtx $ sublangLog callStack "DB" (WarnLogMsg "oops")

            logged <- readSingleLog (testLogQueue env)
            case logMsg logged of
                WarnLogMsg msg -> msg `shouldBe` "oops"
                _ -> expectationFailure "Expected WarnLogMsg"
            case logged of
                AppLogMsgWithContext _ (LogContext actualMap) _ ->
                    actualMap `shouldBe` M.fromList [("lang", "DB"), ("request_id", "abc")]
            pure ()

    describe "glog in a queue-writer GLogFunc context" $ do
        it "writes to the TQueue" $ do
            queue <- newTQueueIO
            let genLogFuncVal = mkGLogFunc $ \_cs msg -> atomically $ writeTQueue queue msg
                logApp = Log.LogApp noopLogFunc genLogFuncVal queue
            runRIO logApp $ glog (AppLogMsgWithContext (AppLogMsg "hello") mempty Nothing)
            logged <- readSingleLog queue
            case logMsg logged of
                AppLogMsg "hello" -> pure ()
                _ -> expectationFailure "Expected AppLogMsg \"hello\""

    describe "logWorker" $ do
        it "reads from queue and invokes its GLogFunc" $ do
            queue <- newTQueueIO
            capturedRef <- newIORef Nothing :: IO (IORef (Maybe AppLogMsgWithContext))
            let genLogFuncVal = mkGLogFunc $ \_cs msg -> writeIORef capturedRef (Just msg)
                logApp = Log.LogApp noopLogFunc genLogFuncVal queue
                testMsg = AppLogMsgWithContext (WarnLogMsg "worker-test") mempty Nothing
            atomically $ writeTQueue queue testMsg
            withAsync (runRIO logApp Log.logWorker) $ \_asyncThread -> do
                -- Poll until the worker consumes the message
                let pollForResult :: Int -> IO AppLogMsgWithContext
                    pollForResult attempts = do
                        mv <- readIORef capturedRef
                        case mv of
                            Just msg -> pure msg
                            Nothing
                                | attempts <= 0 -> do
                                    expectationFailure "logWorker did not consume the message in time"
                                    error "unreachable"
                                | otherwise -> threadDelay 10000 >> pollForResult (attempts - 1)
                captured <- pollForResult 50
                case logMsg captured of
                    WarnLogMsg "worker-test" -> pure ()
                    _ -> expectationFailure "logWorker captured wrong message"

    describe "logAppFromDefaultApp" $ do
        it "creates a LogApp with a fresh stdout-printing GLogFunc" $ do
            queue <- newTQueueIO
            let genLogFuncVal = mkGLogFunc $ \_cs msg -> atomically $ writeTQueue queue msg
                dummyApp = App
                    { logFunc = noopLogFunc
                    , genLogFunc = genLogFuncVal
                    , pgDbConnection = unsafeCoerce ()
                    , pgDbConnectionReadOnly = Nothing
                    , appMainDb = unsafeCoerce ()
                    , appProcessContext = unsafeCoerce ()
                    , botEnvs = mempty
                    , jwtSettings = unsafeCoerce ()
                    , logQueue = queue
                    , extraContext = mempty
                    , logContext = (mempty :: LoggingContext)
                    , mailCreds = unsafeCoerce ()
                    , asyncTasks = unsafeCoerce ()
                    , aiMethods = unsafeCoerce ()
                    , sqlLogAction = unsafeCoerce ()
                    , serviceLib = unsafeCoerce ()
                    }
            let logApp = logAppFromDefaultApp dummyApp
            -- Calling the LogApp's genLogFunc should NOT write to the queue
            -- (it prints to stdout instead)
            let testMsg = AppLogMsgWithContext (AppLogMsg "stdout-msg") mempty Nothing
            runRIO logApp $ glog testMsg
            isEmpty <- atomically $ isEmptyTQueue queue
            isEmpty `shouldBe` True
