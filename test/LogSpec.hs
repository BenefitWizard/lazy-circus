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
import LazyCircus.Testing.Performer
    ( readLogWithContext
    , runScenarioProgram
    , runWithDefaultMocks
    )
import LazyCircus.App.Log qualified as Log
import RIO hiding (logInfo)
import RIO.Map qualified as M
import RIO.Text qualified as Text
import RIO.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec
import Common
import DemoEnv (DemoConfig(..), defaultDemoConfig, withDemoApp)
import LazyCircus.Scene.DB (find)
import LazyCircus.Script (Script (DBScriptDef))
import LazyCircus.Scenario (DbMode (..), evalScript, logInfo, withLogContext)
import SimpleServiceLib (AllServices)

-- | A no-op LogFunc for tests that do not need RIO's standard logging.
noopLogFunc :: LogFunc
noopLogFunc = mkLogFunc $ \_cs _src _lvl _msg -> pure ()

-- | Test environment carrying only the capabilities needed by logging unit tests.
data TestLogEnv = TestLogEnv
    { testLogQueue :: LogQueue
    , testLogContext :: LoggingContext
    }

-- | Provides access to the shared test log queue.
instance HasLogQueue TestLogEnv where
    logQueueL = lens testLogQueue (\env queue -> env{testLogQueue = queue})

-- | Provides access to the structured logging context used by tests.
instance HasLoggingContext TestLogEnv where
    logContextL = lens testLogContext (\env ctx -> env{testLogContext = ctx})

-- | Check whether a log message carries timing context (elapsed_ms key).
hasTimingCtx :: AppLogMsgWithContext -> Bool
hasTimingCtx (AppLogMsgWithContext _ (LogContext ctx) _) =
    M.member "elapsed_ms" ctx

-- | Fixed rendering timestamp: 2026-09-13T12:34:56Z.
sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 9 13) (secondsToDiffTime 45296)

-- | Timestamp prefix shared by every rendered line.
tsPrefix :: Text
tsPrefix = "2026-09-13T12:34:56Z"

-- | Contextualize a payload with a fixed call site and a two-pair context.
withSampleMeta :: AppLogMsg -> AppLogMsgWithContext
withSampleMeta payload = AppLogMsgWithContext
    payload
    (LogContext $ M.fromList [("key", "v1"), ("key2", "v2")])
    (Just (Log.CallSite "Bot.Router" 113))

-- | Contextualize a payload with a call site but an empty context.
withoutCtx :: AppLogMsg -> AppLogMsgWithContext
withoutCtx payload = AppLogMsgWithContext payload (LogContext M.empty) (Just (Log.CallSite "Bot.Router" 113))

-- | Expected bracketed tag for a payload, mirroring 'Log.renderLogLine'.
tagOf :: AppLogMsg -> Text
tagOf AppLogMsg{} = "INFO"
tagOf WarnLogMsg{} = "WARN"
tagOf ErrorLogMsg{} = "ERROR"
tagOf SensitiveLogMsg{} = "SENSITIVE"
tagOf NoticeLogMsg{} = "NOTICE"

-- | Render a message at the sample timestamp and decode the line to Text.
renderedAt :: AppLogMsgWithContext -> Text
renderedAt = utf8BuilderToText . Log.renderLogLine sampleTime

mkEnv :: IO TestLogEnv
mkEnv = do
    queue <- newTQueueIO
    pure $ TestLogEnv queue mempty

readSingleLog :: LogQueue -> IO AppLogMsgWithContext
readSingleLog queue = atomically $ readTQueue queue

-- | Pre-load a queue, run 'Log.logWorker' under the given profile and collect
-- what reaches its GLogFunc; asserts the queue was fully drained.
runWorkerCapturing ::
    Log.LogProfile ->
    Int ->
    [AppLogMsgWithContext] ->
    IO [AppLogMsgWithContext]
runWorkerCapturing profile expectedAccepted msgs = do
    queue <- newTQueueIO
    capturedRef <- newIORef [] :: IO (IORef [AppLogMsgWithContext])
    let genLogFuncVal = mkGLogFunc $ \_cs msg -> modifyIORef' capturedRef (msg :)
        logApp = Log.LogApp noopLogFunc genLogFuncVal queue profile
    mapM_ (atomically . writeTQueue queue) msgs
    withAsync (runRIO logApp Log.logWorker) $ \_workerThread -> do
        let pollForCapture attempts
                | attempts <= (0 :: Int) = do
                    expectationFailure "logWorker did not consume the messages in time"
                    error "unreachable"
                | otherwise = do
                    captured <- readIORef capturedRef
                    queueDrained <- atomically $ isEmptyTQueue queue
                    if length captured >= expectedAccepted && queueDrained
                        then pure (reverse captured)
                        else threadDelay 10000 >> pollForCapture (attempts - 1)
        pollForCapture 50

-- | Run a test action with a DefaultApp used for logging-runtime assertions.
withLogApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withLogApp action =
    withDemoApp
        defaultDemoConfig
            { cfgSmtpLogin = "test@example.com"
            , cfgSmtpName = "Test"
            }
        action

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

    describe "shouldRender" $ do
        it "LogDev renders sensitive and notice messages" $ do
            Log.shouldRender Log.LogDev (withSampleMeta (SensitiveLogMsg "secret")) `shouldBe` True
            Log.shouldRender Log.LogDev (withSampleMeta (NoticeLogMsg "fyi")) `shouldBe` True
        it "LogProd drops sensitive and notice messages" $ do
            Log.shouldRender Log.LogProd (withSampleMeta (SensitiveLogMsg "secret")) `shouldBe` False
            Log.shouldRender Log.LogProd (withSampleMeta (NoticeLogMsg "fyi")) `shouldBe` False
        it "renders info, warn and error messages under both profiles" $
            forM_ [AppLogMsg "hello", WarnLogMsg "hmm", ErrorLogMsg "boom"] $ \payload -> do
                Log.shouldRender Log.LogDev (withSampleMeta payload) `shouldBe` True
                Log.shouldRender Log.LogProd (withSampleMeta payload) `shouldBe` True

    describe "renderLogLine" $ do
        it "renders an info line with call site and context" $
            renderedAt (withSampleMeta (AppLogMsg "hello")) `shouldBe`
                "2026-09-13T12:34:56Z [INFO] Bot.Router:113 | hello | key=v1 key2=v2"
        it "tags warn, error, sensitive and notice lines" $ do
            renderedAt (withSampleMeta (WarnLogMsg "hmm")) `shouldBe`
                "2026-09-13T12:34:56Z [WARN] Bot.Router:113 | hmm | key=v1 key2=v2"
            renderedAt (withSampleMeta (ErrorLogMsg "boom")) `shouldBe`
                "2026-09-13T12:34:56Z [ERROR] Bot.Router:113 | boom | key=v1 key2=v2"
            renderedAt (withSampleMeta (SensitiveLogMsg "secret")) `shouldBe`
                "2026-09-13T12:34:56Z [SENSITIVE] Bot.Router:113 | secret | key=v1 key2=v2"
            renderedAt (withSampleMeta (NoticeLogMsg "fyi")) `shouldBe`
                "2026-09-13T12:34:56Z [NOTICE] Bot.Router:113 | fyi | key=v1 key2=v2"
        it "omits the trailing context segment when the context is empty" $
            renderedAt (withoutCtx (AppLogMsg "hello")) `shouldBe`
                "2026-09-13T12:34:56Z [INFO] Bot.Router:113 | hello"
        it "starts every rendered line with the timestamp and bracketed tag" $
            forM_ [AppLogMsg "hello", WarnLogMsg "hmm", ErrorLogMsg "boom", SensitiveLogMsg "secret", NoticeLogMsg "fyi"] $ \payload ->
                (tsPrefix <> " [" <> tagOf payload <> "] ")
                    `Text.isPrefixOf` renderedAt (withSampleMeta payload)
                    `shouldBe` True

    describe "glog in a queue-writer GLogFunc context" $ do
        it "writes to the TQueue" $ do
            queue <- newTQueueIO
            let genLogFuncVal = mkGLogFunc $ \_cs msg -> atomically $ writeTQueue queue msg
                logApp = Log.LogApp noopLogFunc genLogFuncVal queue Log.LogDev
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
                logApp = Log.LogApp noopLogFunc genLogFuncVal queue Log.LogDev
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

        it "LogProd profile drains the queue but drops the sensitive message" $ do
            captured <- runWorkerCapturing Log.LogProd 1
                [ AppLogMsgWithContext (SensitiveLogMsg "worker-secret") mempty Nothing
                , AppLogMsgWithContext (AppLogMsg "worker-visible") mempty Nothing
                ]
            case captured of
                [AppLogMsgWithContext (AppLogMsg "worker-visible") _ _] -> pure ()
                _ -> expectationFailure "Expected only the visible info message"

        it "LogDev profile drains the queue and emits every message" $ do
            captured <- runWorkerCapturing Log.LogDev 2
                [ AppLogMsgWithContext (SensitiveLogMsg "worker-secret") mempty Nothing
                , AppLogMsgWithContext (AppLogMsg "worker-visible") mempty Nothing
                ]
            case captured of
                [ AppLogMsgWithContext (SensitiveLogMsg "worker-secret") _ _
                  , AppLogMsgWithContext (AppLogMsg "worker-visible") _ _
                  ] -> pure ()
                _ -> expectationFailure "Expected both messages in emission order"

    describe "logAppFromDefaultApp" $ do
        it "creates a LogApp with a fresh stdout-printing GLogFunc" $ withLogApp $ \app -> do
            let logApp = logAppFromDefaultApp Log.LogDev app
                testMsg = AppLogMsgWithContext (AppLogMsg "stdout-msg") mempty Nothing
            runRIO logApp $ glog testMsg
            isEmpty <- atomically $ isEmptyTQueue (logQueue app)
            isEmpty `shouldBe` True

    aroundAll withLogApp $ do
        describe "test runtime log capture" $ do
            it "captures merged scenario log context and call-site metadata" $ \app -> do
                (mocks, ()) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ withLogContext [("request_id", "log-123"), ("user_id", "42")] $ do
                        logInfo "contextual scenario log"

                captured <- readLogWithContext mocks
                case captured of
                    [AppLogMsgWithContext (AppLogMsg "contextual scenario log") (LogContext ctx) mCallSite] -> do
                        M.lookup "lang" ctx `shouldBe` Just "Scenario"
                        M.lookup "request_id" ctx `shouldBe` Just "log-123"
                        M.lookup "user_id" ctx `shouldBe` Just "42"
                        mCallSite `shouldSatisfy` isJust
                    _ -> expectationFailure "Expected one contextual scenario log"

        describe "performer operation timing" $ do
            it "emits timing log for DB Find via shared instance" $ \app -> do
                (mocks, _) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ evalScript $
                        DBScriptDef simpleDb ReadWrite $ find (CircusActId 999 :: CircusActId)
                captured <- readLogWithContext mocks
                let timingLogs = filter hasTimingCtx captured
                null timingLogs `shouldBe` False
                -- Verify the first timing log has correct structure
                case timingLogs of
                    [] -> expectationFailure "Expected at least one timing log"
                    (AppLogMsgWithContext _ (LogContext ctx) _ : _) -> do
                        M.lookup "lang" ctx `shouldBe` Just "DB"
                        M.lookup "op" ctx `shouldBe` Just "Find"
                        M.lookup "elapsed_ms" ctx `shouldSatisfy` isJust
                        -- elapsed_ms should be a non-empty string
                        case M.lookup "elapsed_ms" ctx of
                            Just ms -> ms `shouldSatisfy` (not . Text.null)
                            Nothing -> expectationFailure "elapsed_ms missing from context"
