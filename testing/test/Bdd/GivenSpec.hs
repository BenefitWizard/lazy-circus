{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Unit tests for the Given-phase context materializers ('AppContext' and the
-- 'stagedTgDownloads' \/ 'queuedAiAnswers' \/ 'withAppSeed' action producers).
--
-- Uses ONLY the mock staging APIs — NO live DB, NO bot, NO tgTest: download
-- staging and AI queueing are asserted against freshly allocated 'Mocks'
-- capture buffers, seed accumulation against the pure context slot. Includes
-- the R4 regression: the DEFAULT context is EMPTY — wiring mocks alone stages
-- and seeds nothing, and staging into the unwired default context fails
-- loudly instead of silently no-op'ing.
module Bdd.GivenSpec (spec) where

import Control.Exception (displayException)
import Data.List (isInfixOf)
import Data.Text.Encoding qualified as TE
import LazyCircus.Testing.Bdd.Gherkin (GherkinKeyword (..), GherkinScenario (..), GherkinStep (..))
import LazyCircus.Testing.Bdd.Given
import LazyCircus.Testing.Bdd.Step
    ( StepError
    , StepOutcome (..)
    , StepRegistry
    , givenDef
    , mkRegistry
    , runScenarioSteps
    )
import LazyCircus.Testing.Performer (AiMock (..), Mocks (..), TgMock (..), createAiMock, makeMocks)
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.Usage (Usage (..))
import RIO
import RIO.HashMap qualified as HM
import RIO.Vector qualified as V
import Telegram.Bot.API.Types (FileId (..))
import Test.Hspec

spec :: Spec
spec = do
    describe "stagedTgDownloads" $ do
        it "stages canned downloads into the wired mock's download store" $ do
            mocks <- makeMocks
            _ <- stagedTgDownloads [(FileId "doc-1", bytes "PDF-BYTES"), (FileId "doc-2", bytes "TXT")] (appContextFor mocks)
            downloads <- readSomeRef (downloadableFiles (tgMock mocks))
            HM.lookup "doc-1" downloads `shouldBe` Just (bytes "PDF-BYTES")
            HM.lookup "doc-2" downloads `shouldBe` Just (bytes "TXT")

        it "composes as a Given def: staged downloads land in the wired mock" $ do
            mocks <- makeMocks
            let registry =
                    mkRegistry
                        [ givenDef "file doc-1 is downloadable" (stagedTgDownloads [(FileId "doc-1", bytes "PDF-BYTES")])
                        ]
                steps = [st GivenKeyword 2 "file doc-1 is downloadable"]
            result <- runGivens registry steps (appContextFor mocks)
            case result of
                Right _ -> do
                    downloads <- readSomeRef (downloadableFiles (tgMock mocks))
                    HM.lookup "doc-1" downloads `shouldBe` Just (bytes "PDF-BYTES")
                Left err -> expectationFailure ("unexpected error: " <> show err)

    describe "queuedAiAnswers" $ do
        it "appends canned answers to the wired mock's queue in FIFO order" $ do
            mocks <- makeMocks
            _ <- queuedAiAnswers [completion "1st", completion "2nd"] (appContextFor mocks)
            queue <- readSomeRef (aiResponses (aiMock mocks))
            map completionMarker queue `shouldBe` ["1st", "2nd"]

        it "queues after already-queued answers (FIFO preserved)" $ do
            mocks <- makeMocks
            seeded <- createAiMock [completion "earlier"]
            let ctx = (appContextFor mocks){ctxAiMock = Just seeded}
            _ <- queuedAiAnswers [completion "later"] ctx
            queue <- readSomeRef (aiResponses seeded)
            map completionMarker queue `shouldBe` ["earlier", "later"]

    describe "withAppSeed" $ do
        it "accumulates seeds in seeding order" $ do
            ctx <- withAppSeed "alice" emptyAppContext >>= withAppSeed "bob"
            ctxSeeds (ctx :: AppContext Text) `shouldBe` ["alice", "bob"]

        it "composes as Given defs: seeds accumulate through the interpreter" $ do
            let registry =
                    mkRegistry
                        [ givenDef "app seeded with alice" (withAppSeed "alice")
                        , givenDef "app seeded with bob" (withAppSeed "bob")
                        ]
                steps =
                    [ st GivenKeyword 2 "app seeded with alice"
                    , st GivenKeyword 3 "app seeded with bob"
                    ]
            result <- runGivens registry steps emptyAppContext
            case result of
                Right outcome -> ctxSeeds (stepOutcomeContext outcome) `shouldBe` ["alice", "bob"]
                Left err -> expectationFailure ("unexpected error: " <> show err)

    describe "empty default context (R4)" $ do
        it "the default context is empty: no staging targets, no seeds" $ do
            isNothing (ctxTgMock (emptyAppContext :: AppContext Text)) `shouldBe` True
            isNothing (ctxAiMock (emptyAppContext :: AppContext Text)) `shouldBe` True
            ctxSeeds (emptyAppContext :: AppContext Text) `shouldBe` []

        it "the default context is empty: wiring mocks alone stages and seeds nothing" $ do
            mocks <- makeMocks
            let registry =
                    mkRegistry
                        [ givenDef "file doc-1 is downloadable" (stagedTgDownloads [(FileId "doc-1", "PDF-BYTES")])
                        , givenDef "assistant answer 4 queued" (queuedAiAnswers [completion "4"])
                        , givenDef "a clean slate" pure
                        ]
                -- a fixture-free scenario: the only executed Given stages nothing
                steps = [st GivenKeyword 2 "a clean slate"]
            result <- runGivens registry steps (appContextFor mocks)
            case result of
                Right outcome -> do
                    ctxSeeds (stepOutcomeContext outcome) `shouldBe` []
                    downloads <- readSomeRef (downloadableFiles (tgMock mocks))
                    HM.toList downloads `shouldBe` []
                    queue <- readSomeRef (aiResponses (aiMock mocks))
                    queue `shouldSatisfy` null
                Left err -> expectationFailure ("unexpected error: " <> show err)

        it "staging into the default context fails loudly (no implicit staging)" $ do
            stagedTgDownloads [(FileId "doc-1", "PDF-BYTES")] emptyAppContext
                `shouldThrow` stagingWiringError "no Telegram mock"
            queuedAiAnswers [completion "4"] emptyAppContext
                `shouldThrow` stagingWiringError "no AI mock"

--------------------------------------------------------------------------------
-- Test stack
--------------------------------------------------------------------------------

-- | Runs a scenario on the canonical BDD stack: 'IO' interpreter, 'AppContext'
-- with 'Text' seeds, unit dialog state and no emitted values.
runGivens
    :: StepRegistry IO (AppContext Text) () ()
    -> [GherkinStep]
    -> AppContext Text
    -> IO (Either StepError (StepOutcome (AppContext Text) () ()))
runGivens registry steps ctx0 = runScenarioSteps registry (mkScenario steps) ctx0 ()

-- | Assembles a scenario; the header line is irrelevant to the interpreter.
mkScenario :: [GherkinStep] -> GherkinScenario
mkScenario steps = GherkinScenario "test scenario" [] steps 1

-- | Builds a step with an explicit 1-based line number.
st :: GherkinKeyword -> Int -> Text -> GherkinStep
st kw line text = GherkinStep kw text line

-- | UTF-8 bytes of a text literal — the canned download payloads.
bytes :: Text -> ByteString
bytes = TE.encodeUtf8

-- | The FIFO marker a completion was built with (its @id@ field).
completionMarker :: Chat.ChatCompletionObject -> Text
completionMarker Chat.ChatCompletionObject{Chat.id = marker} = marker

-- | Builds a one-choice assistant completion whose id doubles as the FIFO
-- marker the assertions read back via 'completionMarker'.
completion :: Text -> Chat.ChatCompletionObject
completion marker =
    Chat.ChatCompletionObject
        { Chat.id = marker
        , Chat.choices =
            V.fromList
                [ Chat.Choice
                    { Chat.finish_reason = "stop"
                    , Chat.index = 0
                    , Chat.message =
                        Chat.Assistant
                            { Chat.assistant_content = Just marker
                            , Chat.refusal = Nothing
                            , Chat.name = Nothing
                            , Chat.assistant_audio = Nothing
                            , Chat.tool_calls = Nothing
                            , Chat.extra = Nothing
                            }
                    , Chat.logprobs = Nothing
                    }
                ]
        , Chat.created = 0
        , Chat.model = "test-model"
        , Chat.reasoning_effort = Nothing
        , Chat.service_tier = Nothing
        , Chat.system_fingerprint = Nothing
        , Chat.object = "chat.completion"
        , Chat.usage = Usage 0 0 0 Nothing Nothing
        }

-- | Selector: a thrown 'StringException' whose message blames the missing
-- mock wiring.
stagingWiringError :: String -> StringException -> Bool
stagingWiringError needle e = needle `isInfixOf` displayException e
