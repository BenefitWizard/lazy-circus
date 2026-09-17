{-# LANGUAGE OverloadedStrings #-}

-- | Hspec coverage for 'degradeSafely' in 'ScenarioProgram'.
module DegradeSafelySpec (spec) where

import LazyCircus.App.Default (DefaultApp)
import LazyCircus.App.Log (AppLogMsg (..))
import LazyCircus.Scenario (degradeSafely, throw)
import LazyCircus.Testing.Performer (readLog, runScenarioProgram, runWithDefaultMocks)
import DemoEnv (defaultDemoConfig, withDemoApp)
import RIO
import RIO.Text qualified as Text
import SimpleServiceLib (AllServices)
import Test.Hspec

-- | Run a test action against a demo app with the default (no external services) config.
withDegradeSafelyApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withDegradeSafelyApp = withDemoApp defaultDemoConfig

spec :: Spec
spec = aroundAll withDegradeSafelyApp $ do
    describe "DegradeSafely" $ do
        it "returns the fallback and logs exactly one warn when the action fails" $ \app -> do
            (mocks, result) <- runWithDefaultMocks app $
                runScenarioProgram $ degradeSafely "flaky-operation" (0 :: Int) $
                    throw (userError "boom")

            result `shouldBe` 0
            logs <- readLog mocks
            case logs of
                [WarnLogMsg msg] -> do
                    "flaky-operation: " `Text.isPrefixOf` msg `shouldBe` True
                    "boom" `Text.isInfixOf` msg `shouldBe` True
                _ -> expectationFailure "Expected exactly one warn log carrying the label and error text"

        it "returns the value and emits no warns when the action succeeds" $ \app -> do
            (mocks, result) <- runWithDefaultMocks app $
                runScenarioProgram $ degradeSafely "flaky-operation" (0 :: Int) $ pure 42

            result `shouldBe` 42
            logs <- readLog mocks
            null logs `shouldBe` True
