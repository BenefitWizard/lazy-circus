{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | hspec tests for callService in ScenarioProgram with real ServiceHandler instances.
module ServiceCallSpec (spec) where

import Control.Exception (SomeException)
import Data.Pool (destroyAllResources)
import DemoEnv (setupDatabase, testConnectionString)
import LazyCircus.App.Log (AppLogMsgWithContext(..), LoggingContext(..))
import LazyCircus.App.Default (DefaultApp (..), DefaultAppConfig (..), MailCreds (..), newDefaultApp)
import LazyCircus.App.Service (runAllWorkers)
import LazyCircus.Scenario (callService, runSafely, withLogContext)
import LazyCircus.Scenario qualified as LC (logInfo)
import LazyCircus.Testing.Performer (readLog, readLogWithContext, runScenarioProgram, runWithDefaultMocks)
import RIO
import RIO.Map qualified as M
import SimpleService
    ( AddExpressionRequest (..),
      AddExpressionResponse (..),
      SimpleRequest (..),
      SimpleResponse (..),
      handleAddExpressionRequest,
      handleSimpleRequest
    )
import SimpleServiceLib
    ( AllServices (..),
      AllServicesConfig (..),
      mkAllServices
    )
import Test.Hspec

-- | Run a test action with a DefaultApp that has real service handlers.
-- Uses aroundAll so the database and services are set up once for all tests.
-- PRE-CONTRACT: PostgreSQL must be reachable at 127.0.0.1:5432.
-- POST-CONTRACT: Database connection pools are released after the action.
withServiceTestApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withServiceTestApp action = do
    setupDatabase
    bracket
        ( do
            let config = AllServicesConfig
                    { simpleRequest = handleSimpleRequest
                    , addExpressionRequest = handleAddExpressionRequest
                    }
            (allServices, workers) <- mkAllServices config
            _ <- runAllWorkers workers
            app <- newDefaultApp $
                DefaultAppConfig
                    { cfgPgConnectionString = testConnectionString
                    , cfgPgConnectionStringReadOnly = Nothing
                    , cfgPgPoolMaxResources = 10
                    , cfgBotConfigs = []
                    , cfgAiApiKey = Nothing
                    , cfgAiBaseUrl = Nothing
                    , cfgMailCreds = MailCreds "127.0.0.1" 1025 "test" "" "Test" False
                    , cfgExtraContext = mempty
                    , cfgSqlLogAction = Nothing
                    , cfgServiceLib = allServices
                    }
            pure app
        )
        ( \app' -> do
            destroyAllResources (pgDbPool app')
            mapM_ destroyAllResources (pgDbPoolReadOnly app')
        )
        action

spec :: Spec
spec = aroundAll withServiceTestApp $ do
    describe "callService" $ do
        it "callService (Add 3 4) returns SimpleResult 7" $ \app -> do
            (_, result) <- runWithDefaultMocks app $ do
                runScenarioProgram $ callService (Add 3 4)
            result `shouldBe` SimpleResult 7

        it "callService (Subtract 10 3) returns SimpleResult 7" $ \app -> do
            (_, result) <- runWithDefaultMocks app $ do
                runScenarioProgram $ callService (Subtract 10 3)
            result `shouldBe` SimpleResult 7

        it "callService (AddExpressionRequest hello) returns AddExpressionResult" $ \app -> do
            (_, result) <- runWithDefaultMocks app $ do
                runScenarioProgram $ callService (AddExpressionRequest "hello")
            result `shouldBe` AddExpressionResult "hello!"

        it "callService works inside runSafely" $ \app -> do
            (_, result) <- runWithDefaultMocks app $ do
                runScenarioProgram $ runSafely @SomeException $ callService (Add 5 5)
            result `shouldSatisfy` \case
                Right (SimpleResult 10) -> True
                _ -> False

        it "callService can be combined with logInfo" $ \app -> do
            (mocks, result) <- runWithDefaultMocks app $ do
                runScenarioProgram $ do
                    LC.logInfo "Before service call"
                    res <- callService (Add 1 2)
                    LC.logInfo "After service call"
                    pure res
            result `shouldBe` SimpleResult 3
            logs <- readLog mocks
            length logs `shouldBe` 2

        it "preserves surrounding log context across service calls" $ \app -> do
            (mocks, result) <- runWithDefaultMocks app $ do
                runScenarioProgram $
                    withLogContext [("request_id", "svc-42"), ("feature", "service-call")] $ do
                        LC.logInfo "Before contextual service call"
                        callService (Add 2 8)

            result `shouldBe` SimpleResult 10

            contextualLogs <- readLogWithContext mocks
            case contextualLogs of
                [AppLogMsgWithContext _ (LogContext ctx) mCallSite] -> do
                    M.lookup "lang" ctx `shouldBe` Just "Scenario"
                    M.lookup "request_id" ctx `shouldBe` Just "svc-42"
                    M.lookup "feature" ctx `shouldBe` Just "service-call"
                    mCallSite `shouldSatisfy` isJust
                _ -> expectationFailure "Expected exactly one contextual log entry"
