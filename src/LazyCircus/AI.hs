{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}

-- | AI integration layer — builds OpenAI chat-completion requests, sends them via
-- a lens-provided V1.Methods handle, and decodes structured JSON responses.
--
-- SCOPE: Covers request construction, execution against the OpenAI API, and
-- response decoding / error logging. Does NOT define prompt-template types
-- (see "LazyCircus.AI.POML") or the concrete runtime wiring (see
-- "LazyCircus.App.Default").
module LazyCircus.AI
    ( AIRequest(..)
    , AgentRequest(..)
    , HasAIMethods(..)
    , askAI
    , solveWithAgentLoop
    ) where

import Data.Aeson (FromJSON, Value, eitherDecodeStrictText, object, (.=))
import Data.Aeson.Text (encodeToLazyText)
import qualified Data.Text.Lazy as TL (toStrict)
import LazyCircus.AI.POML (renderPOMLtoPrompt)
import LazyCircus.AI.POML.Types (POML)
import LazyCircus.App.Log (AppLogMsg (SensitiveLogMsg), AppLogMsgWithContext (..), HasLoggingContext, logContextL)
import LazyCircus.App.Service (HasToolCallExec (..), HasToolDescriptions (..), ToolCallExec (..), ToolDescription (..))
import OpenAI.V1 qualified as V1
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.Models qualified as Models (Model)
import OpenAI.V1.Tool qualified as Tool
import OpenAI.V1.ToolCall qualified as TC
import RIO
import RIO.Vector ((!?))
import qualified RIO.Vector as V

-- data Model = DeepSeek deriving (Show, Eq)

-- | Request payload for a structured AI completion.
data AIRequest a = AIRequest
    { prompt :: [POML]       -- ^ user-facing prompt fragments
    , systemPrompt :: [POML] -- ^ system-level instruction fragments
    , outputType :: Proxy a  -- ^ phantom proxy guiding JSON decode target
    }

-- | Default model used for AI completions.
defaultModel :: Models.Model
defaultModel = "deepseek-v4-flash"

-- | OpenAI API finish reason indicating the model wants to call tools.
finishReasonToolCalls :: Text
finishReasonToolCalls = "tool_calls"

-- | Request payload for an agent-loop AI completion with tool use.
data AgentRequest a = AgentRequest
    { agentPrompt        :: [POML]    -- ^ user-facing prompt fragments
    , agentSystemPrompt  :: [POML]    -- ^ system-level instruction fragments
    , agentMaxIterations :: Natural   -- ^ maximum ReAct iterations before giving up (must be >= 0, guaranteed by 'Natural')
    }

-- | Environment capability that exposes the OpenAI client methods used by this module.
class HasAIMethods env where
    aiMethodsL :: Lens' env V1.Methods

{- | Execute a typed AI request and decode the first chat-completion response.
PRE-CONTRACT: The environment provides OpenAI methods through 'aiMethodsL', and the model returns a JSON payload matching the requested response type.
POST-CONTRACT: Returns the decoded first response when present and decodable, otherwise 'Nothing'.
-}
askAI :: (HasAIMethods env, HasGLogFunc env, GMsg env ~ AppLogMsgWithContext, HasLoggingContext env, MonadReader env m, MonadIO m, FromJSON a) => AIRequest a -> m (Maybe a)
askAI (AIRequest prompt systemPrompt _outputType) = do
    V1.Methods{V1.createChatCompletion} <- view aiMethodsL
    let
        req =
            Chat._CreateChatCompletion
                { Chat.model = defaultModel
                , Chat.response_format = Just Chat.JSON_Object
                , Chat.messages =
                    [ Chat.System
                        { content =
                            [ Chat.Text $ renderPOMLtoPrompt systemPrompt
                            ]
                        , name = Nothing
                        }
                    , Chat.User
                        { content = [Chat.Text $ renderPOMLtoPrompt prompt]
                        , name = Nothing
                        }
                    ]
                }
    Chat.ChatCompletionObject{choices} <- liftIO $ createChatCompletion req
    let rawContent = do
            Chat.Choice{message} <- choices !? 0
            pure $ Chat.messageToContent message
        decoded = eitherDecodeStrictText <$> rawContent
    logCtx <- view logContextL
    case decoded of
        Just (Right a) -> pure (Just a)
        Just (Left err) -> do
            let msg =
                    AppLogMsgWithContext
                        { logMsg = SensitiveLogMsg $ "AI decode error: " <> fromString err
                        , logContext = logCtx
                        , logCallSite = Nothing
                        }
            glog msg
            pure Nothing
        Nothing -> pure Nothing

-- | Encode an Aeson 'Value' to strict 'Text'.
-- POST-CONTRACT: Result is the JSON serialisation of the input value.
encodeValueToText :: Value -> Text
encodeValueToText = TL.toStrict . encodeToLazyText

-- | Convert a 'ToolDescription' to an OpenAI 'Tool.Function' wrapper.
-- POST-CONTRACT: The returned tool has a name and description from the input,
--   parameters defaulting to @{"type": "object"}@ when absent.
toOpenAITool :: ToolDescription -> Tool.Tool
toOpenAITool ToolDescription{toolDescName, toolDescDescription, toolDescParameters} = Tool.Tool_Function Tool.Function
    { Tool.name = toolDescName
    , Tool.description = Just toolDescDescription
    , Tool.parameters = toolDescParameters <|> Just (object ["type" .= ("object" :: Text)])
    , Tool.strict = Nothing
    }

-- | Run a multi-turn agent loop with tool use.
-- The loop sends the conversation history to the model, processes any
-- tool calls in the response by executing them via 'ToolCallExec', appends
-- the results, and repeats until the model returns a final answer or the
-- iteration budget is exhausted.
--
-- PRE-CONTRACT: The environment provides AI methods, tool descriptions, and
--   tool execution through the respective lenses. 'agentMaxIterations' uses
--   'Natural' so negative values are impossible.
-- POST-CONTRACT: Returns the decoded final response when the agent converges
--   within the iteration budget, otherwise 'Nothing'.
solveWithAgentLoop ::
    ( HasAIMethods env
    , HasToolDescriptions env
    , HasToolCallExec env
    , HasGLogFunc env
    , GMsg env ~ AppLogMsgWithContext
    , HasLoggingContext env
    , MonadReader env m
    , MonadUnliftIO m
    , FromJSON b
    ) => AgentRequest b -> m (Maybe b)
solveWithAgentLoop AgentRequest{agentPrompt, agentSystemPrompt, agentMaxIterations} = go agentMaxIterations initialMessages
  where
    initialMessages = V.fromList
        [ Chat.System
            { content = [Chat.Text $ renderPOMLtoPrompt agentSystemPrompt]
            , name = Nothing
            }
        , Chat.User
            { content = [Chat.Text $ renderPOMLtoPrompt agentPrompt]
            , name = Nothing
            }
        ]

    go 0 _ = pure Nothing
    go remaining history = do
        V1.Methods{V1.createChatCompletion} <- view aiMethodsL
        toolDescs <- view toolDescriptionsL
        ToolCallExec exec <- view toolCallExecL

        let tools = if null toolDescs then Nothing
                    else Just $ V.fromList $ map toOpenAITool toolDescs
            req = Chat._CreateChatCompletion
                { Chat.model = defaultModel
                , Chat.messages = history
                , Chat.tools = tools
                , Chat.tool_choice = guard (not (null toolDescs)) >> Just Tool.ToolChoiceAuto
                }
                -- NOTE: response_format is NOT set for agent-loop requests because the model
                -- must be free to return tool_calls during intermediate rounds. The system prompt
                -- must instruct the model to return JSON when it has a final answer.

        Chat.ChatCompletionObject{choices} <- liftIO $ createChatCompletion req

        case choices !? 0 of
            Nothing -> pure Nothing
            Just Chat.Choice{message, finish_reason} ->
                case message of
                    Chat.Assistant{Chat.tool_calls = Just tcs}
                        | not (V.null tcs) && finish_reason == finishReasonToolCalls -> do
                            toolResults <- forM (toList tcs) $ \tc ->
                                case tc of
                                    TC.ToolCall_Function{TC.id = callId, TC.function = TC.Function{TC.name = toolName, TC.arguments = argsText}} -> do
                                        let argsValue = case eitherDecodeStrictText argsText of
                                                Right v -> v
                                                Left _ -> object ["raw_arguments" .= argsText]
                                        result <- tryAny $ liftIO $ exec toolName argsValue
                                        let encodedResult = case result of
                                                Right v  -> encodeValueToText v
                                                Left err -> encodeValueToText $ object
                                                    [ "error" .= (fromString (displayException err) :: Text) ]
                                        pure (callId, encodedResult)
                            let assistantMsg = Chat.Assistant
                                    { Chat.assistant_content = Just [Chat.Text $ Chat.messageToContent message]
                                    , Chat.refusal = Nothing
                                    , Chat.name = Nothing
                                    , Chat.assistant_audio = Nothing
                                    , Chat.tool_calls = Just tcs
                                    }
                                toolMsgs = map (\(tid, result) ->
                                    Chat.Tool { content = [Chat.Text result], tool_call_id = tid }
                                    ) toolResults
                            go (remaining - 1) (history <> V.fromList (assistantMsg : toolMsgs))
                    _ -> decodeContent (Chat.messageToContent message)

    decodeContent content
        | content == "" = pure Nothing
        | otherwise = case eitherDecodeStrictText content of
            Right a -> pure (Just a)
            Left err -> do
                logCtx <- view logContextL
                glog $ AppLogMsgWithContext
                    { logMsg = SensitiveLogMsg $ "Agent decode error: " <> fromString err
                    , logContext = logCtx
                    , logCallSite = Nothing
                    }
                pure Nothing
