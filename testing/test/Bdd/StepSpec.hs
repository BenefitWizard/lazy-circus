{-# LANGUAGE OverloadedStrings #-}

-- | Unit tests for the step-definition interpreter ('runScenarioSteps').
--
-- Uses a pure-ish stack — @'StateT' [Text] IO@ as the effect monad, an 'Int'
-- dialog state, a 'Text' context and 'Text' emitted values. NO Telegram, NO
-- tgTest. Covers document-order execution (the EIM pattern: a second When
-- after a Then), the Given-after-When\/Then phase violation with its line
-- number, keyword participation in matching (a Then step does not select a
-- When-registered pattern), context\/state threading observed through the
-- collected values, literal-before-template selection determinism (the
-- shared registry selector), duplicate-parameter rejection, and the
-- structural undefined-step error with line and text.
module Bdd.StepSpec (spec) where

import Control.Monad.Trans.State.Strict (StateT, modify', runStateT)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import LazyCircus.Testing.Bdd.Gherkin
import LazyCircus.Testing.Bdd.Pattern (Pattern (..), lookupParam)
import LazyCircus.Testing.Bdd.Step
import Test.Hspec

spec :: Spec
spec = do
    describe "runScenarioSteps" $ do
        it "executes steps in document order (second When after Then works — the EIM pattern)" $
            do
                let steps =
                        [ st GivenKeyword 2 "a user"
                        , st WhenKeyword 3 "user \"alice\" acts"
                        , st ThenKeyword 4 "role \"admin\" assigned"
                        , st WhenKeyword 5 "user \"alice\" departs"
                        , st ThenKeyword 6 "role \"admin\" revoked"
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
                            [ whenDef "user \"name\" acts" (\_params -> bump "acts")
                            , givenDef "a user" (\_params -> appendContext "A")
                            ]
                    steps =
                        [ st WhenKeyword 3 "user \"alice\" acts"
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
                let registry = mkRegistry [whenDef "user \"name\" acts" (\_params -> bump "acts")]
                    steps = [st ThenKeyword 3 "user \"alice\" acts"]
                (result, _) <- runSteps registry steps
                result
                    `shouldBe` Left
                        (StepError
                            { stepErrorScenario = "test scenario"
                            , stepErrorLine = 3
                            , stepErrorStepText = "user \"alice\" acts"
                            , stepErrorReason = StepKeywordMismatch WhenKeyword
                            })

        it "threads context and state across steps (asserted via collected values)" $
            do
                let registry =
                        mkRegistry
                            [ givenDef "context starts" (\_params -> appendContext "A")
                            , givenDef "context grows" (\_params -> appendContext "B")
                            , whenDef "action happens" (\_params -> bump "act")
                            , thenDef "all good" (\_params -> bump "check")
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

        it "selects the literal definition over a matching template regardless of registration order (strict semantics)" $
            do
                let capture = whenDef "user \"$x\" acts" (\_params -> bump "capture")
                    exact = whenDef (Literal "user \"mary\" acts") (\_params -> bump "exact")
                    steps = [st WhenKeyword 3 "user \"mary\" acts"]
                (captureFirst, _) <- runSteps (mkRegistry [capture, exact]) steps
                (exactFirst, _) <- runSteps (mkRegistry [exact, capture]) steps
                mapM_
                    ( \result -> case result of
                        Right outcome -> do
                            stepOutcomeValues outcome `shouldBe` ["exact:1"]
                            map stepRunParams (stepOutcomeSteps outcome)
                                `shouldBe` [[]]
                        other -> expectationFailure ("unexpected error: " <> show other)
                    )
                    [captureFirst, exactFirst]

        it "keeps registration order between two matching templates of the same phase" $
            do
                let wider = whenDef "user \"name\" acts" (\_params -> bump "wider")
                    narrower = whenDef "user \"alice\" acts" (\_params -> bump "narrower")
                    steps = [st WhenKeyword 3 "user \"alice\" acts"]
                (widerFirst, _) <- runSteps (mkRegistry [wider, narrower]) steps
                (narrowerFirst, _) <- runSteps (mkRegistry [narrower, wider]) steps
                case widerFirst of
                    Right outcome -> stepOutcomeValues outcome `shouldBe` ["wider:1"]
                    other -> expectationFailure ("unexpected error: " <> show other)
                case narrowerFirst of
                    Right outcome -> stepOutcomeValues outcome `shouldBe` ["narrower:1"]
                    other -> expectationFailure ("unexpected error: " <> show other)

        it "passes the captured parameters into the step action (StepParams)" $
            do
                let registry =
                        mkRegistry
                            [ whenDef "user \"$x\" acts" $ \params s -> do
                                let name = fromMaybe "" (lookupParam "$x" params)
                                modify' (++ [name])
                                pure (s + 1, Just (name <> ":1"))
                            ]
                    steps = [st WhenKeyword 3 "user \"mary\" acts"]
                (result, dialogLog) <- runSteps registry steps
                case result of
                    Right outcome -> do
                        stepOutcomeValues outcome `shouldBe` ["mary:1"]
                        dialogLog `shouldBe` ["mary"]
                    other -> expectationFailure ("unexpected error: " <> show other)

        it "fails a step whose pattern binds a parameter twice, with the step's line, before running the action" $
            do
                let registry = mkRegistry [whenDef "\"$x\" then \"$x\"" (\_params -> bump "never")]
                    steps = [st WhenKeyword 9 "\"a\" then \"a\""]
                (result, dialogLog) <- runSteps registry steps
                dialogLog `shouldBe` []
                result
                    `shouldBe` Left
                        (StepError
                            { stepErrorScenario = "test scenario"
                            , stepErrorLine = 9
                            , stepErrorStepText = "\"a\" then \"a\""
                            , stepErrorReason = StepDuplicateParam "$x"
                            })

        it "reports an unmatched step as a structural error with line and text" $
            do
                let registry = mkRegistry [whenDef "user \"name\" acts" (\_params -> bump "acts")]
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
        [ givenDef "a user" (\_params -> appendContext "A")
        , whenDef "user \"name\" acts" (\_params -> bump "acts")
        , thenDef "role \"role\" assigned" (\_params -> bump "assigned")
        , whenDef "user \"name\" departs" (\_params -> bump "departs")
        , thenDef "role \"role\" revoked" (\_params -> bump "revoked")
        ]
