{-# LANGUAGE OverloadedStrings #-}

-- | hspec tests for 'runArbitraryIO' in 'ScenarioProgram'.
module ArbitraryIOSpec (spec) where

import LazyCircus.App.Default (DefaultApp)
import LazyCircus.App.Log (AppLogMsg (..))
import LazyCircus.Scenario (logInfo, runArbitraryIO)
import LazyCircus.Testing.Performer (readLog, runScenarioProgram, runWithDefaultMocks)
import DemoEnv (defaultDemoConfig, withDemoApp)
import RIO hiding (logInfo)
import SimpleServiceLib (AllServices)
import Test.Hspec

-- | Run a test action against a demo app with the default (no external services) config.
withArbitraryIOApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withArbitraryIOApp = withDemoApp defaultDemoConfig

spec :: Spec
spec = aroundAll withArbitraryIOApp $ do
    describe "runArbitraryIO" $ do
        it "returns the result of the supplied IO action" $ \app -> do
            (_, result) <- runWithDefaultMocks app $ do
                runScenarioProgram $ runArbitraryIO $ pure (42 :: Int)
            result `shouldBe` 42

        it "actually executes the side effect" $ \app -> do
            ref <- newIORef (0 :: Int)
            (_, result) <- runWithDefaultMocks app $ do
                runScenarioProgram $ runArbitraryIO $ writeIORef ref 7 $> 7
            refValue <- readIORef ref
            refValue `shouldBe` 7
            result `shouldBe` (7 :: Int)

        it "composes with logInfo in the surrounding scenario" $ \app -> do
            (mocks, result) <- runWithDefaultMocks app $ do
                runScenarioProgram $ do
                    logInfo "before"
                    v <- runArbitraryIO $ pure (99 :: Int)
                    logInfo "after"
                    pure v
            result `shouldBe` 99
            logs <- readLog mocks
            length logs `shouldBe` 2
