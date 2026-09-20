{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | hspec tests for fire-and-forget service casts (castService): mailbox
-- transport semantics, scenario-level dispatch, and the test capture buffer.
module ServiceCastSpec (spec) where

import Data.Pool (destroyAllResources)
import DemoEnv (setupDatabase, testConnectionString)
import LazyCircus.App.Default (DefaultApp (..), DefaultAppConfig (..), MailCreds (..), newDefaultApp)
import LazyCircus.App.Service qualified as S
import LazyCircus.Scenario (callService, castService)
import LazyCircus.Testing.Performer (readCastRequestsOfType, runScenarioProgram, runWithDefaultMocks)
import RIO
import SimpleService
    ( SimpleRequest (..),
      SimpleResponse (..),
      handleAddExpressionRequest,
      handleSecureRequest,
      handleSimpleRequest
    )
import SimpleServiceLib (AllServices, AllServicesConfig (..), mkAllServices)
import Test.Hspec

-- | Standard handler configuration mirroring ServiceCallSpec.
standardConfig :: AllServicesConfig IO
standardConfig =
    AllServicesConfig
        { simpleRequest = handleSimpleRequest
        , addExpressionRequest = handleAddExpressionRequest
        , secureRequest = handleSecureRequest
        }

-- | Run a test action with a DefaultApp wired to the given service handlers.
-- PRE-CONTRACT: PostgreSQL must be reachable at 127.0.0.1:5432.
-- POST-CONTRACT: Database connection pools are released after the action.
withServiceApp :: AllServicesConfig IO -> (DefaultApp AllServices -> IO a) -> IO a
withServiceApp config action = do
    setupDatabase
    bracket
        ( do
            (allServices, workers) <- mkAllServices config
            _ <- S.runAllWorkers workers
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
spec = do
    describe "service mailbox transport" $ do
        it "cast runs the cast handler and delivers the request" $ do
            received <- newEmptyMVar
            (h, w) <- S.createServiceWithCast
                (\req -> putMVar received req)
                (\_ -> pure (SimpleResult 0))
            withAsync w $ \_ -> do
                S.castService h (Add 1 2)
                result <- timeout 2_000_000 (takeMVar received)
                result `shouldBe` Just (Add 1 2)

        it "cast returns before the handler finishes" $ do
            release <- newEmptyMVar
            finished <- newEmptyMVar
            (h, w) <- S.createServiceWithCast
                (\_ -> takeMVar release >> putMVar finished ())
                (\_ -> pure (SimpleResult 0))
            withAsync w $ \_ -> do
                sent <- timeout 1_000_000 (S.castService h (Add 0 0))
                sent `shouldSatisfy` isJust
                -- Drain the cast so the worker finishes cleanly before withAsync cancels it.
                putMVar release ()
                handled <- timeout 2_000_000 (takeMVar finished)
                handled `shouldSatisfy` isJust

        it "processes a cast before a later call (FIFO)" $ do
            markers <- newIORef []
            (h, w) <- S.createServiceWithCast
                (\_ -> modifyIORef' markers ("cast" :))
                (\_ -> do
                    modifyIORef' markers ("call" :)
                    pure (SimpleResult 7)
                )
            withAsync w $ \_ -> do
                S.castService h (Add 0 0)
                result <- S.callService h (Subtract 5 2)
                result `shouldBe` SimpleResult 7
                ordered <- reverse <$> readIORef markers
                ordered `shouldBe` ["cast" :: Text, "call"]

        it "keeps serving calls after a cast handler exception" $ do
            (h, w) <- S.createServiceWithCast
                (\_ -> throwIO (userError "cast blew up"))
                (\req -> pure (SimpleResult (addX req + addY req)))
            withAsync w $ \_ -> do
                S.castService h (Add 0 0)
                result <- S.callService h (Add 2 3)
                result `shouldBe` SimpleResult 5

    describe "castService in ScenarioProgram" $
        aroundAll (withServiceApp standardConfig) $ do
            it "records sent casts in the capture buffer" $ \app -> do
                (mocks, ()) <- runWithDefaultMocks app $
                    runScenarioProgram $ do
                        castService (Add 3 4)
                        castService (Subtract 10 3)
                casts <- readCastRequestsOfType mocks
                casts `shouldBe` [Add 3 4, Subtract 10 3]

            it "can be interleaved with callService" $ \app -> do
                (mocks, result) <- runWithDefaultMocks app $
                    runScenarioProgram $ do
                        castService (Add 1 1)
                        callService (Add 2 2)
                result `shouldBe` SimpleResult 4
                casts <- readCastRequestsOfType mocks
                casts `shouldBe` [Add 1 1]

    describe "TH-generated castFromServiceLib" $
        it "overrides the blocking default (returns while the handler is stuck)" $ do
            stuck <- newEmptyMVar
            let stuckConfig = standardConfig
                    { simpleRequest = \req -> takeMVar stuck >> handleSimpleRequest req
                    }
            withServiceApp stuckConfig $ \app -> do
                sent <- timeout 2_000_000 $
                    runWithDefaultMocks app $ runScenarioProgram $ castService (Add 1 1)
                case sent of
                    Just _ -> pure ()
                    Nothing -> expectationFailure "castService blocked on a stuck handler"
                -- Unblock the worker so it does not linger past the test.
                putMVar stuck ()
