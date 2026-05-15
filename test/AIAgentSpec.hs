{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Tests for the AI agent loop (solveWithAgent and solveWithAgentLoop).
--
-- The first group tests the test performer's default implementation
-- (solveWithAgent' = pure Nothing). The second group tests the production
-- agent loop (solveWithAgentLoop) directly by mocking the OpenAI API client.
module AIAgentSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import DemoEnv (DemoConfig(..), defaultDemoConfig, withDemoApp)
import LazyCircus.AI (AgentRequest(..), HasAIMethods(..), solveWithAgentLoop)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.App.Service (HasToolCallExec(..), ToolCallExec(..), ToolDescription(..))
import SimpleServiceLib (AllServices)
import LazyCircus.Scenario (evalScript)
import LazyCircus.Scene.AI (solveWithAgent)
import LazyCircus.Script (Script(..))
import LazyCircus.Testing.Performer (runWithDefaultMocks, runScenarioProgram)
import OpenAI.V1 qualified as V1
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.ToolCall qualified as TC
import OpenAI.V1.Usage (Usage(..))
import RIO
import RIO.Vector qualified as V
import Test.Hspec

-- | Minimal configuration for AI tests.
testConfig :: DemoConfig
testConfig =
    defaultDemoConfig
        { cfgSmtpLogin = "test@example.com"
        , cfgSmtpName = "Test"
        }

-- | Run a test action with a DefaultApp.
withTestApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withTestApp action = withDemoApp testConfig $ \app -> action app

-- | Create a ChatCompletionObject with a single Assistant choice.
--   Used to build mock API responses for testing solveWithAgentLoop.
mockCompletion contentText toolCalls finishReason = Chat.ChatCompletionObject
    { Chat.id = "test-id"
    , Chat.choices = V.fromList
        [ Chat.Choice
            { finish_reason = finishReason
            , index = 0
            , message = Chat.Assistant
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

spec :: Spec
spec = do
    aroundAll withTestApp $ do
        describe "solveWithAgent (test performer - returns Nothing)" $ do
            it "returns Nothing in test environment without API calls" $ \app -> do
                let req = AgentRequest
                        { agentPrompt = ["Calculate 2+2"]
                        , agentSystemPrompt = ["You are a calculator."]
                        , agentMaxIterations = 5
                        , thinkingEnabled = False
                        }
                    script :: Script (Maybe Value)
                    script = AIScriptDef [] (solveWithAgent req)
                (_, result) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ evalScript script
                result `shouldBe` (Nothing :: Maybe Value)

            it "returns Nothing even with maxIterations = 0 in test environment" $ \app -> do
                let req = AgentRequest
                        { agentPrompt = ["test"]
                        , agentSystemPrompt = ["test"]
                        , agentMaxIterations = 0
                        , thinkingEnabled = False
                        }
                    script :: Script (Maybe Value)
                    script = AIScriptDef [] (solveWithAgent req)
                (_, result) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ evalScript script
                result `shouldBe` (Nothing :: Maybe Value)

            it "returns Nothing with non-zero tool descriptions in test environment" $ \app -> do
                let req = AgentRequest
                        { agentPrompt = ["test"]
                        , agentSystemPrompt = ["test"]
                        , agentMaxIterations = 3
                        , thinkingEnabled = False
                        }
                    dummyDescs = [ToolDescription "test_tool" "A test tool" Nothing]
                    script :: Script (Maybe Value)
                    script = AIScriptDef dummyDescs (solveWithAgent req)
                (_, result) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ evalScript script
                result `shouldBe` (Nothing :: Maybe Value)

        describe "solveWithAgentLoop (production code path)" $ do
            it "returns Nothing when maxIterations = 0 without API call" $ \app -> do
                apiCalledRef <- newIORef False
                let mockMethods = (app ^. aiMethodsL) { V1.createChatCompletion = \_ -> do
                        atomicModifyIORef' apiCalledRef (\_ -> (True, ()))
                        fail "API should not have been called"
                    }
                let req :: AgentRequest Value = AgentRequest
                        { agentPrompt = ["test"]
                        , agentSystemPrompt = ["test"]
                        , agentMaxIterations = 0
                        , thinkingEnabled = False
                        }
                result <- runRIO (app & aiMethodsL .~ mockMethods) (solveWithAgentLoop req)
                result `shouldBe` Nothing
                readIORef apiCalledRef >>= (`shouldBe` False)

            it "returns decoded value from direct response with stop" $ \app -> do
                let mockMethods = (app ^. aiMethodsL) { V1.createChatCompletion = \_ ->
                        pure $ mockCompletion "{\"result\": 42}" Nothing "stop"
                    }
                let req :: AgentRequest Value = AgentRequest
                        { agentPrompt = ["test"]
                        , agentSystemPrompt = ["test"]
                        , agentMaxIterations = 5
                        , thinkingEnabled = False
                        }
                result <- runRIO (app & aiMethodsL .~ mockMethods) (solveWithAgentLoop req)
                result `shouldBe` Just (object ["result" .= (42 :: Int)])

            it "executes tool calls and returns final result" $ \app -> do
                toolCallCountRef <- newIORef (0 :: Int)
                let toolCall1 = TC.ToolCall_Function
                        { TC.id = "call_1"
                        , TC.function = TC.Function
                            { TC.name = "get_status"
                            , TC.arguments = "{}"
                            }
                        }
                    firstResponse = mockCompletion "Let me check." (Just (V.fromList [toolCall1])) "tool_calls"
                    secondResponse = mockCompletion "{\"status\": \"ok\", \"code\": 200}" Nothing "stop"
                responsesRef <- newIORef [firstResponse, secondResponse]
                let mockMethods = (app ^. aiMethodsL) { V1.createChatCompletion = \_ ->
                        atomicModifyIORef' responsesRef $ \case
                            [] -> error "No more mock responses"
                            (r:rest) -> (rest, r)
                    }
                    mockExec = ToolCallExec $ \toolName _argsValue -> do
                        atomicModifyIORef' toolCallCountRef (\c -> (c + 1, ()))
                        pure $ object ["status" .= ("executed" :: Text), "tool" .= toolName]
                let req :: AgentRequest Value = AgentRequest
                        { agentPrompt = ["test"]
                        , agentSystemPrompt = ["test"]
                        , agentMaxIterations = 5
                        , thinkingEnabled = False
                        }
                result <- runRIO (app & aiMethodsL .~ mockMethods & toolCallExecL .~ mockExec) (solveWithAgentLoop req)
                result `shouldBe` Just (object ["status" .= ("ok" :: Text), "code" .= (200 :: Int)])
                readIORef toolCallCountRef >>= (`shouldBe` 1)

            it "returns Nothing when maxIterations is exhausted with tool calls" $ \app -> do
                callCountRef <- newIORef (0 :: Int)
                let toolCall = TC.ToolCall_Function
                        { TC.id = "call_1"
                        , TC.function = TC.Function
                            { TC.name = "loop_tool"
                            , TC.arguments = "{}"
                            }
                        }
                    mockMethods = (app ^. aiMethodsL) { V1.createChatCompletion = \_ -> do
                            atomicModifyIORef' callCountRef (\c -> (c + 1, ()))
                            pure $ mockCompletion "keep going" (Just (V.fromList [toolCall])) "tool_calls"
                        }
                    mockExec = ToolCallExec $ \_ _ -> pure $ object ["result" .= ("ok" :: Text)]
                let req :: AgentRequest Value = AgentRequest
                        { agentPrompt = ["test"]
                        , agentSystemPrompt = ["test"]
                        , agentMaxIterations = 2
                        , thinkingEnabled = False
                        }
                result <- runRIO (app & aiMethodsL .~ mockMethods & toolCallExecL .~ mockExec) (solveWithAgentLoop req)
                result `shouldBe` Nothing
                readIORef callCountRef >>= (`shouldBe` 2)

            it "returns Nothing when content is empty" $ \app -> do
                let mockMethods = (app ^. aiMethodsL) { V1.createChatCompletion = \_ ->
                        pure $ mockCompletion "" Nothing "stop"
                    }
                let req :: AgentRequest Value = AgentRequest
                        { agentPrompt = ["test"]
                        , agentSystemPrompt = ["test"]
                        , agentMaxIterations = 5
                        , thinkingEnabled = False
                        }
                result <- runRIO (app & aiMethodsL .~ mockMethods) (solveWithAgentLoop req)
                result `shouldBe` Nothing

            it "wraps plain-text content as JSON string fallback" $ \app -> do
                let mockMethods = (app ^. aiMethodsL) { V1.createChatCompletion = \_ ->
                        pure $ mockCompletion "not valid json {{{" Nothing "stop"
                    }
                let req :: AgentRequest Value = AgentRequest
                        { agentPrompt = ["test"]
                        , agentSystemPrompt = ["test"]
                        , agentMaxIterations = 5
                        , thinkingEnabled = False
                        }
                result <- runRIO (app & aiMethodsL .~ mockMethods) (solveWithAgentLoop req)
                result `shouldBe` Just (String "not valid json {{{")

            it "returns Nothing when API returns empty choices" $ \app -> do
                let mockMethods = (app ^. aiMethodsL) { V1.createChatCompletion = \_ ->
                        pure $ Chat.ChatCompletionObject
                            { Chat.id = "test-id"
                            , Chat.choices = V.empty
                            , Chat.created = 0
                            , Chat.model = "test-model"
                            , Chat.reasoning_effort = Nothing
                            , Chat.service_tier = Nothing
                            , Chat.system_fingerprint = Nothing
                            , Chat.object = "chat.completion"
                            , Chat.usage = Usage 0 0 0 Nothing Nothing
                            }
                    }
                let req :: AgentRequest Value = AgentRequest
                        { agentPrompt = ["test"]
                        , agentSystemPrompt = ["test"]
                        , agentMaxIterations = 5
                        , thinkingEnabled = False
                        }
                result <- runRIO (app & aiMethodsL .~ mockMethods) (solveWithAgentLoop req)
                result `shouldBe` Nothing

            it "sends thinking extra in request when thinkingEnabled is True" $ \app -> do
                requestRef <- newIORef (Nothing :: Maybe Chat.CreateChatCompletion)
                let mockMethods = (app ^. aiMethodsL) { V1.createChatCompletion = \req -> do
                        writeIORef requestRef (Just req)
                        pure $ mockCompletion "{\"ok\": true}" Nothing "stop"
                    }
                let req :: AgentRequest Value = AgentRequest
                        { agentPrompt = ["test"]
                        , agentSystemPrompt = ["test"]
                        , agentMaxIterations = 5
                        , thinkingEnabled = True
                        }
                result <- runRIO (app & aiMethodsL .~ mockMethods) (solveWithAgentLoop req)
                result `shouldBe` Just (object ["ok" .= True])
                sentReq <- readIORef requestRef
                case sentReq of
                    Just Chat.CreateChatCompletion{Chat.extra = Just extraObj} -> do
                        KM.lookup "thinking" extraObj `shouldSatisfy` isJust
                    Just Chat.CreateChatCompletion{Chat.extra = Nothing} ->
                        expectationFailure "Expected extra to be Just, got Nothing"
                    Nothing -> expectationFailure "No request was captured"

            it "preserves reasoning_content extra through tool-call iterations" $ \app -> do
                let reasoningContent = "step 1: analyze the problem" :: Text
                    extraObj = KM.fromList [("reasoning_content", String reasoningContent)]
                    toolCall1 = TC.ToolCall_Function
                        { TC.id = "call_1"
                        , TC.function = TC.Function
                            { TC.name = "get_status"
                            , TC.arguments = "{}"
                            }
                        }
                    firstResponse = Chat.ChatCompletionObject
                        { Chat.id = "test-id"
                        , Chat.choices = V.fromList
                            [ Chat.Choice
                                { finish_reason = "tool_calls"
                                , index = 0
                                , message = Chat.Assistant
                                    { Chat.assistant_content = Just "thinking..."
                                    , Chat.refusal = Nothing
                                    , Chat.name = Nothing
                                    , Chat.assistant_audio = Nothing
                                    , Chat.tool_calls = Just (V.fromList [toolCall1])
                                    , Chat.extra = Just extraObj
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
                    secondResponse = mockCompletion "{\"status\": \"done\"}" Nothing "stop"
                requestsRef <- newIORef ([] :: [Chat.CreateChatCompletion])
                counterRef <- newIORef (0 :: Int)
                let mockMethods = (app ^. aiMethodsL) { V1.createChatCompletion = \req -> do
                        atomicModifyIORef' requestsRef (\rs -> (rs ++ [req], ()))
                        n <- atomicModifyIORef' counterRef (\c -> (c + 1, c))
                        pure $ if n == 0 then firstResponse else secondResponse
                    }
                    mockExec = ToolCallExec $ \_ _ -> pure $ object ["status" .= ("ok" :: Text)]
                let req :: AgentRequest Value = AgentRequest
                        { agentPrompt = ["test"]
                        , agentSystemPrompt = ["test"]
                        , agentMaxIterations = 5
                        , thinkingEnabled = True
                        }
                result <- runRIO (app & aiMethodsL .~ mockMethods & toolCallExecL .~ mockExec) (solveWithAgentLoop req)
                result `shouldBe` Just (object ["status" .= ("done" :: Text)])
                allReqs <- readIORef requestsRef
                length allReqs `shouldBe` 2
                let secondReq = allReqs !! 1
                case V.toList (Chat.messages secondReq) of
                    [_, _, assistantMsg, _] ->
                        Chat.messageExtra assistantMsg `shouldBe` Just extraObj
                    _ -> expectationFailure $ "Expected 4 messages in second request, got " ++ show (V.length (Chat.messages secondReq))
