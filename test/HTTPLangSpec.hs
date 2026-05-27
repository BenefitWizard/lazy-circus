{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- | Hspec coverage for the HTTP scene language dispatch, logging, and context propagation.
module HTTPLangSpec (spec) where

import Data.Aeson (Value)
import Data.Proxy (Proxy (..))
import DemoEnv (DemoConfig (..), defaultDemoConfig, withDemoApp)
import LazyCircus (httpScript)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.App.Log
    ( AppLogMsg (..)
    , AppLogMsgWithContext (AppLogMsgWithContext, logContext, logMsg)
    , LoggingContext (LogContext)
    )
import LazyCircus.Scenario (evalScript)
import LazyCircus.Scene.HTTP (runClient, slogInfo, slogWarn, swithLogCtx)
import LazyCircus.Script (Script (..))
import LazyCircus.Testing.Performer (readLogWithContext, runScenarioProgram, runWithDefaultMocks)
import RIO
import RIO.Map qualified as M
import Servant.API (Get, JSON, type (:>))
import Servant.Client (BaseUrl, ClientError, ClientM, client, parseBaseUrl)
import SimpleServiceLib (AllServices)
import Test.Hspec

-- | Minimal servant API for testing runClient with a real HTTP request.
type TestAPI = "test" :> Get '[JSON] Value

-- | Generated client function for the test API.
testGet :: ClientM Value
testGet = client (Proxy @TestAPI)

-- | Test configuration matching the pattern used in AIAgentSpec.
testConfig :: DemoConfig
testConfig =
    defaultDemoConfig
        { cfgSmtpLogin = "test@example.com"
        , cfgSmtpName = "Test"
        }

-- | Run a test action with a DefaultApp.
withTestApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withTestApp action = withDemoApp testConfig $ \app -> action app

-- | Parse a BaseUrl, throwing on failure (impossible for a hard-coded valid URL).
parseTestUrl :: IO BaseUrl
parseTestUrl = parseBaseUrl "http://127.0.0.1:1"

spec :: Spec
spec = do
    aroundAll withTestApp $ do
        describe "HTTPScript dispatch" $ do
            it "dispatches HTTPScriptDef and returns Left on connection failure" $ \app -> do
                baseUrl <- parseTestUrl
                let script :: Script (Either ClientError Value)
                    script = httpScript baseUrl $ runClient testGet
                (_, result) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ evalScript script
                case result of
                    Left _ -> pure ()
                    Right _ -> expectationFailure "Expected Left (connection failure), got Right"

            it "dispatches HTTPScriptDef with logging-only script" $ \app -> do
                baseUrl <- parseTestUrl
                let script :: Script ()
                    script = httpScript baseUrl $ slogInfo "test log from HTTP"
                (_, result) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ evalScript script
                result `shouldBe` ()

        describe "HTTPScript logging" $ do
            it "captures slogInfo messages with HTTP language tag" $ \app -> do
                baseUrl <- parseTestUrl
                let script :: Script ()
                    script = httpScript baseUrl $ slogInfo "http-test-message"
                (mocks, _) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ evalScript script
                captured <- readLogWithContext mocks
                case captured of
                    [AppLogMsgWithContext (AppLogMsg "http-test-message") (LogContext ctx) _] -> do
                        M.lookup "lang" ctx `shouldBe` Just "HTTP"
                    _ ->
                        expectationFailure $
                            "Expected exactly one log entry, got " ++ show (length captured)

            it "captures slogWarn messages" $ \app -> do
                baseUrl <- parseTestUrl
                let script :: Script ()
                    script = httpScript baseUrl $ slogWarn "http-warn-message"
                (mocks, _) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ evalScript script
                captured <- readLogWithContext mocks
                case captured of
                    [AppLogMsgWithContext (WarnLogMsg "http-warn-message") _ _] -> pure ()
                    _ ->
                        expectationFailure $
                            "Expected one WarnLogMsg, got " ++ show (length captured)

            it "propagates logging context through swithLogCtx" $ \app -> do
                baseUrl <- parseTestUrl
                let script :: Script ()
                    script = httpScript baseUrl $ do
                        swithLogCtx [("request_id", "req-456")] $ do
                            slogInfo "contextual-http-log"
                (mocks, _) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ evalScript script
                captured <- readLogWithContext mocks
                case captured of
                    [AppLogMsgWithContext (AppLogMsg "contextual-http-log") (LogContext ctx) _] -> do
                        M.lookup "lang" ctx `shouldBe` Just "HTTP"
                        M.lookup "request_id" ctx `shouldBe` Just "req-456"
                    _ ->
                        expectationFailure $
                            "Expected one contextual log, got " ++ show (length captured)
