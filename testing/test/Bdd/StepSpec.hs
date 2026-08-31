{-# LANGUAGE OverloadedStrings #-}

-- | Unit tests for the step-definition interpreter ('runScenarioSteps').
--
-- Uses a pure-ish stack — @'StateT' [Text] IO@ as the effect monad, an 'Int'
-- dialog state, a 'Text' context and 'Text' emitted values. NO Telegram, NO
-- tgTest. Covers document-order execution (the EIM pattern: a second When
-- after a Then), the Given-after-When\/Then phase violation with its line
-- number, keyword participation in matching (a Then step does not select a
-- When-registered pattern), context\/state threading observed through the
-- collected values, first-registered-match-wins determinism, and the
-- structural undefined-step error with line and text.
module Bdd.StepSpec (spec) where

import Control.Monad.Trans.State.Strict (StateT, modify', runStateT)
import Data.Text (Text)
import Data.Text qualified as T
import LazyCircus.Testing.Bdd.Gherkin
import LazyCircus.Testing.Bdd.Step
import Test.Hspec

spec :: Spec
spec = do
    describe "runScenarioSteps" $ do
        it "executes steps in document order (second When after Then works — the EIM pattern)" $
            do
                let steps =
                        [ st GivenKeyword 2 "a user"
                        , st WhenKeyword 3 "user alice acts"
                        , st ThenKeyword 4 "role admin assigned"
                        , st WhenKeyword 5 "user alice departs"
                        , st ThenKeyword 6 "role admin revoked"
                        ]
                (result, dialogLog) <- runSteps eimRegistry steps
                case result of
                    Right outcome -> do
                        stepOutcomeValues outcome
                            `shouldBe` ["acts:1", "assigned:2", "departs:3", "revoked:4"]
                        dialogLog `shouldBe` ["acts", "assigned", "departs", "revoked"]
                    other -> expectationFailure ("unexpected error: " <> show other)

        it "rejects a Given after the first When/Then with the line number" $
            do
                let registry =
                        mkRegistry
                            [ whenDef "user \"name\" acts" (bump "acts")
                            , givenDef "a user" (appendContext "A")
                            ]
                    steps =
                        [ st WhenKeyword 3 "user alice acts"
                        , st GivenKeyword 4 "a user"
                        ]
                (result, _) <- runSteps registry steps
                result
                    `shouldBe` Left
                        (StepError
                            { stepErrorScenario = "test scenario"
                            , stepErrorLine = 4
                            , stepErrorStepText = "a user"
                            , stepErrorReason = StepGivenAfterDialog
                            })

        it "does not match a Then step against a When-registered pattern (resolved keyword participates)" $
            do
                let registry = mkRegistry [whenDef "user \"name\" acts" (bump "acts")]
                    steps = [st ThenKeyword 3 "user alice acts"]
                (result, _) <- runSteps registry steps
                result
                    `shouldBe` Left
                        (StepError
                            { stepErrorScenario = "test scenario"
                            , stepErrorLine = 3
                            , stepErrorStepText = "user alice acts"
                            , stepErrorReason = StepKeywordMismatch WhenKeyword
                            })

        it "threads context and state across steps (asserted via collected values)" $
            do
                let registry =
                        mkRegistry
                            [ givenDef "context starts" (appendContext "A")
                            , givenDef "context grows" (appendContext "B")
                            , whenDef "action happens" (bump "act")
                            , thenDef "all good" (bump "check")
                            ]
                    steps =
                        [ st GivenKeyword 2 "context starts"
                        , st GivenKeyword 3 "context grows"
                        , st WhenKeyword 4 "action happens"
                        , st ThenKeyword 5 "all good"
                        ]
                (result, _) <- runSteps registry steps
                case result of
                    Right outcome -> do
                        stepOutcomeContext outcome `shouldBe` "AB"
                        stepOutcomeValues outcome `shouldBe` ["act:1", "check:2"]
                        stepOutcomeState outcome `shouldBe` 2
                    other -> expectationFailure ("unexpected error: " <> show other)

        it "selects the first registered matching definition when two patterns of the same phase match" $
            do
                let greedy = whenDef "user \"name\"" (bump "greedy")
                    exact = whenDef "user \"name\" acts" (bump "exact")
                    steps = [st WhenKeyword 3 "user alice acts"]
                (greedyFirst, _) <- runSteps (mkRegistry [greedy, exact]) steps
                (exactFirst, _) <- runSteps (mkRegistry [exact, greedy]) steps
                case greedyFirst of
                    Right outcome -> do
                        stepOutcomeValues outcome `shouldBe` ["greedy:1"]
                        map stepRunParams (stepOutcomeSteps outcome)
                            `shouldBe` [[("name", "alice acts")]]
                    other -> expectationFailure ("unexpected error: " <> show other)
                case exactFirst of
                    Right outcome -> do
                        stepOutcomeValues outcome `shouldBe` ["exact:1"]
                        map stepRunParams (stepOutcomeSteps outcome)
                            `shouldBe` [[("name", "alice")]]
                    other -> expectationFailure ("unexpected error: " <> show other)

        it "reports an unmatched step as a structural error with line and text" $
            do
                let registry = mkRegistry [whenDef "user \"name\" acts" (bump "acts")]
                    steps = [st WhenKeyword 7 "nobody registered this"]
                (result, _) <- runSteps registry steps
                result
                    `shouldBe` Left
                        (StepError
                            { stepErrorScenario = "test scenario"
                            , stepErrorLine = 7
                            , stepErrorStepText = "nobody registered this"
                            , stepErrorReason = StepUndefinedStep
                            })

--------------------------------------------------------------------------------
-- Test stack
--------------------------------------------------------------------------------

-- | Effect monad of the tests: 'IO' with a log of executed dialog actions.
type M = StateT [Text] IO

-- | Runs a scenario built from the given steps on the test stack with empty
-- context, zero state and an empty log; returns the interpreter result and
-- the dialog execution log.
runSteps
    :: StepRegistry M Text Int Text
    -> [GherkinStep]
    -> IO (Either StepError (StepOutcome Text Int Text), [Text])
runSteps registry steps = runStateT (runScenarioSteps registry (mkScenario steps) "" 0) []

-- | Assembles a scenario; the header line is irrelevant to the interpreter.
mkScenario :: [GherkinStep] -> GherkinScenario
mkScenario steps = GherkinScenario "test scenario" [] steps 1

-- | Builds a step with an explicit 1-based line number.
st :: GherkinKeyword -> Int -> Text -> GherkinStep
st kw line text = GherkinStep kw text line

-- | A Given action appending @mark@ to the context.
appendContext :: Text -> Text -> IO Text
appendContext mark c = pure (c <> mark)

-- | A Dialog action: logs @tag@, increments the incoming state, and emits
-- @tag:stateAfterIncrement@ — so each collected value proves which incoming
-- state its step observed.
bump :: Text -> Int -> M (Int, Maybe Text)
bump tag s = do
    modify' (++ [tag])
    pure (s + 1, Just (tag <> ":" <> T.pack (show (s + 1))))

-- | Registry covering the EIM steps: one Given, two parametrized Whens, two Thens.
eimRegistry :: StepRegistry M Text Int Text
eimRegistry =
    mkRegistry
        [ givenDef "a user" (appendContext "A")
        , whenDef "user \"name\" acts" (bump "acts")
        , thenDef "role \"role\" assigned" (bump "assigned")
        , whenDef "user \"name\" departs" (bump "departs")
        , thenDef "role \"role\" revoked" (bump "revoked")
        ]
