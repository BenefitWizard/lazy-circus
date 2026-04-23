{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | hspec tests for callService in ScenarioProgram with real ServiceHandler instances.
module ServiceCallSpec (spec) where

import Control.Exception (SomeException)
import Database.PostgreSQL.Simple (close)
import DemoEnv (setupDatabase, testConnectionString)
import LazyCircus.App.Default (DefaultApp (..), DefaultAppConfig (..), MailCreds (..), newDefaultApp)
import LazyCircus.App.Service (runAllWorkers)
import LazyCircus.Scenario (callService, runSafely)
import LazyCircus.Scenario qualified as LC (logInfo)
import LazyCircus.Testing.Performer (readLog, runScenarioProgram, runWithDefaultMocks)
import RIO
import SimpleService
    ( AddExpressionRequest (..),
      AddExpressionResponse (..),
      AllServices (..),
      AllServicesConfig (..),
      SimpleRequest (..),
      SimpleResponse (..),
      handleAddExpressionRequest,
      handleSimpleRequest,
      mkAllServices
    )
import Test.Hspec

-- | Run a test action with a DefaultApp that has real service handlers.
-- Uses aroundAll so the database and services are set up once for all tests.
-- PRE-CONTRACT: PostgreSQL must be reachable at 127.0.0.1:5432.
-- POST-CONTRACT: Database connections are closed after the action.
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
            close (pgDbConnection app')
            mapM_ close (pgDbConnectionReadOnly app')
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
