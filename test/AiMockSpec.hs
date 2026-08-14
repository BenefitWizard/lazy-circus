{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Tests for the AI mock injection infrastructure in the test performer.
--
-- Verifies that 'runWithAiMocks' stages canned 'Chat.ChatCompletionObject'
-- responses that flow through the production AI decode path
-- ('askAIContinuing' via 'evalScript' / 'aiScript'), and that the shared
-- 'Mocks.aiMock' FIFO queue is consumed across multiple 'ask' calls in call
-- order. Also covers backward compatibility: a test that does not stage
-- responses still observes 'Nothing' (the empty-queue fallback yields
-- 'emptyCompletion', which the production decoder turns into 'Nothing').
module AiMockSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import DemoEnv (DemoConfig (..), defaultDemoConfig, withDemoApp)
import LazyCircus.AI (AIRequest (thinkingEnabled), AgentRequest, mkAgentRequest, mkAIRequest)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Scene.AI qualified as Scene (ask, solveWithAgent)
import LazyCircus.Scenario (evalScript)
import LazyCircus.Script (Script (..))
import LazyCircus.Testing.Performer (readAiRequests, runWithAiMocks, runWithDefaultMocks, runScenarioProgram)
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.ToolCall qualified as TC
import OpenAI.V1.Usage (Usage (..))
import RIO
import RIO.Vector qualified as V
import SimpleServiceLib (AllServices)
import Test.Hspec

-- | Minimal configuration for AI tests (mirrors 'AIAgentSpec.testConfig').
testConfig :: DemoConfig
testConfig =
    defaultDemoConfig
        { cfgSmtpLogin = "test@example.com"
        , cfgSmtpName = "Test"
        }

-- | Run a test action with a 'DefaultApp'.
withTestApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withTestApp action = withDemoApp testConfig $ \app -> action app

-- | Build a 'Chat.ChatCompletionObject' with a single Assistant choice carrying
-- the given content text, optional tool calls, and finish reason. Local copy
-- (not exported from 'AIAgentSpec') used to stage canned AI responses.
mockCompletion :: Text -> Maybe (Vector TC.ToolCall) -> Text -> Chat.ChatCompletionObject
mockCompletion contentText toolCalls finishReason =
    Chat.ChatCompletionObject
        { Chat.id = "test-id"
        , Chat.choices =
            V.fromList
                [ Chat.Choice
                    { finish_reason = finishReason
                    , index = 0
                    , message =
                        Chat.Assistant
                            { Chat.assistant_content = Just contentText
                            , Chat.refusal = Nothing
                            , Chat.name = Nothing
                            , Chat.assistant_audio = Nothing
                            , Chat.tool_calls = toolCalls
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

-- | A representative AI request reused across scenarios: a one-shot
-- "calculator" prompt with no thinking and an empty tool list.
calcAiReq :: AIRequest Value
calcAiReq = mkAIRequest ["Calculate 2+2"] ["You are a calculator."]

-- | Same as 'calcAiReq' but with 'thinkingEnabled = True'. Used by scenarios
-- that need to assert the rendered request carries the DeepSeek thinking extra.
calcAiReqThinking :: AIRequest Value
calcAiReqThinking = (mkAIRequest ["Calculate 2+2"] ["You are a calculator."]){thinkingEnabled = True}

-- | A simple @ask@ script (no tools) used across scenarios.
askScript :: Script (Maybe Value)
askScript = AIScriptDef [] (Scene.ask calcAiReq)

spec :: Spec
spec = aroundAll withTestApp $ do
    describe "AiMock performer" $ do
        it "ask returns staged response through test performer" $ \app -> do
            let resp = mockCompletion "{\"a\":1}" Nothing "stop"
            (mocks, result) <-
                runWithAiMocks app [resp] $
                    runScenarioProgram (evalScript askScript)
            result `shouldBe` Just (object ["a" .= (1 :: Int)])
            captured <- readAiRequests mocks
            length captured `shouldBe` 1

        it "shared FIFO queue serves two asks in order" $ \app -> do
            let resp1 = mockCompletion "{\"a\":1}" Nothing "stop"
                resp2 = mockCompletion "{\"a\":2}" Nothing "stop"
            (mocks, (r1, r2)) <-
                runWithAiMocks app [resp1, resp2] $ do
                    r1 <- runScenarioProgram $ evalScript askScript
                    r2 <- runScenarioProgram $ evalScript askScript
                    pure (r1, r2)
            r1 `shouldBe` Just (object ["a" .= (1 :: Int)])
            r2 `shouldBe` Just (object ["a" .= (2 :: Int)])
            captured <- readAiRequests mocks
            length captured `shouldBe` 2

        it "solveWithAgent consumes one completion per iteration" $ \app -> do
            let req :: AgentRequest Value = mkAgentRequest ["test"] ["test"] 5
                script :: Script (Maybe Value) = AIScriptDef [] (Scene.solveWithAgent req)
            (_, result) <-
                runWithAiMocks app [mockCompletion "{\"status\":\"ok\",\"code\":200}" Nothing "stop"] $
                    runScenarioProgram (evalScript script)
            result `shouldBe` Just (object ["status" .= ("ok" :: Text), "code" .= (200 :: Int)])

        it "readAiRequests captures rendered request with system message and thinking extra" $ \app -> do
            let resp = mockCompletion "{\"ok\":true}" Nothing "stop"
            (mocks, _) <-
                runWithAiMocks app [resp] $
                    runScenarioProgram (evalScript (AIScriptDef [] (Scene.ask calcAiReqThinking)))
            requests <- readAiRequests mocks
            length requests `shouldBe` 1
            case requests of
                (firstReq : _) -> do
                    case V.toList (Chat.messages firstReq) of
                        (Chat.System{} : _) -> pure ()
                        _ -> expectationFailure "Expected the first message to be Chat.System"
                    case firstReq of
                        Chat.CreateChatCompletion{Chat.extra = Just extraObj} ->
                            KM.lookup "thinking" extraObj `shouldSatisfy` isJust
                        Chat.CreateChatCompletion{Chat.extra = Nothing} ->
                            expectationFailure "Expected Chat.extra to be Just, got Nothing"
                [] -> expectationFailure "Expected at least one captured request, got []"

        it "empty queue yields Nothing" $ \app -> do
            (_, result) <-
                runWithDefaultMocks app $
                    runScenarioProgram (evalScript askScript)
            result `shouldBe` (Nothing :: Maybe Value)
