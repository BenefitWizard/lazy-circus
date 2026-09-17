{-# LANGUAGE OverloadedStrings #-}

-- | Hspec coverage for 'readExtraContextKnob' in 'ScenarioProgram'.
module ExtraContextKnobSpec (spec) where

import LazyCircus.App.Default (DefaultApp, extraContextL)
import LazyCircus.App.Log (AppLogMsg (..))
import LazyCircus.Scenario (readExtraContextKnob)
import LazyCircus.Testing.Performer (Mocks, readLog, runScenarioProgram, runWithDefaultMocks)
import DemoEnv (defaultDemoConfig, withDemoApp)
import RIO
import RIO.HashMap qualified as HM
import SimpleServiceLib (AllServices)
import Test.Hspec

knobKey :: Text
knobKey = "extra-context-knob-spec-key"

defaultKnob :: Int
defaultKnob = 7

-- | Set the knob key in the app's extra context (deleted when the raw value is Nothing).
withKnobContext :: Maybe Text -> DefaultApp AllServices -> DefaultApp AllServices
withKnobContext raw = extraContextL %~ maybe (HM.delete knobKey) (HM.insert knobKey) raw

-- | Run the knob scenario (Int knob, non-negative predicate) against the app with the
-- given raw extra-context value and return the captured mocks plus the result.
runKnob :: DefaultApp AllServices -> Maybe Text -> IO (Mocks AllServices, Int)
runKnob app raw =
    runWithDefaultMocks (withKnobContext raw app) $
        runScenarioProgram $ readExtraContextKnob knobKey (>= 0) defaultKnob

spec :: Spec
spec = aroundAll (withDemoApp defaultDemoConfig) $
    describe "ExtraContextKnob" $ do
        it "returns the default silently when the key is absent" $ \app -> do
            (mocks, result) <- runKnob app Nothing

            result `shouldBe` defaultKnob
            logs <- readLog mocks
            null logs `shouldBe` True

        it "returns the default with exactly one warn when the raw value does not parse" $ \app -> do
            (mocks, result) <- runKnob app (Just "banana")

            result `shouldBe` defaultKnob
            logs <- readLog mocks
            case logs of
                [WarnLogMsg msg] ->
                    msg `shouldBe`
                        ("Invalid " <> knobKey <> " extra-context value "
                            <> tshow ("banana" :: Text)
                            <> "; falling back to the default "
                            <> tshow defaultKnob)
                _ -> fail ("expected exactly one warn, got " <> show (length logs))

        it "returns the default with exactly one warn when the parsed value fails the predicate" $ \app -> do
            (mocks, result) <- runKnob app (Just "-3")

            result `shouldBe` defaultKnob
            logs <- readLog mocks
            case logs of
                [WarnLogMsg msg] ->
                    msg `shouldBe`
                        ("Invalid " <> knobKey <> " extra-context value "
                            <> tshow ("-3" :: Text)
                            <> "; falling back to the default "
                            <> tshow defaultKnob)
                _ -> fail ("expected exactly one warn, got " <> show (length logs))

        it "returns the parsed value without logging when the raw value is valid" $ \app -> do
            (mocks, result) <- runKnob app (Just "5")

            result `shouldBe` 5
            logs <- readLog mocks
            null logs `shouldBe` True
