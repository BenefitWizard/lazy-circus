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

import Data.Aeson (FromJSON, Object, Value (Object, String), eitherDecodeStrictText, object, (.=))
import qualified Data.Aeson.KeyMap as KM
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
    , thinkingEnabled :: Bool  -- ^ enable DeepSeek thinking mode
    }

-- | Default model used for AI completions.
defaultModel :: Models.Model
defaultModel = "deepseek-v4-flash"

-- | Construct the DeepSeek thinking extra object.
-- POST-CONTRACT: Returns 'Just' with @{"thinking": {"type": "enabled"}}@ when True, 'Nothing' when False.
thinkingExtra :: Bool -> Maybe Object
thinkingExtra True  = Just $ KM.fromList [("thinking", object ["type" .= ("enabled" :: Text)])]
thinkingExtra False = Nothing

-- | Log reasoning_content from a response message's extra field.
-- POST-CONTRACT: Logs reasoning content when present; does nothing otherwise.
logReasoningContent :: (HasGLogFunc env, GMsg env ~ AppLogMsgWithContext, HasLoggingContext env, MonadReader env m, MonadIO m) => Chat.Message content -> m ()
logReasoningContent msg =
    case KM.lookup "reasoning_content" =<< Chat.messageExtra msg of
        Just (String reasoning) -> do
            logCtx <- view logContextL
            glog $ AppLogMsgWithContext
                { logMsg = SensitiveLogMsg $ "AI reasoning: " <> reasoning
                , logContext = logCtx
                , logCallSite = Nothing
                }
        _ -> pure ()

-- | OpenAI API finish reason indicating the model wants to call tools.
finishReasonToolCalls :: Text
finishReasonToolCalls = "tool_calls"

-- | Request payload for an agent-loop AI completion with tool use.
data AgentRequest a = AgentRequest
    { agentPrompt        :: [POML]    -- ^ user-facing prompt fragments
    , agentSystemPrompt  :: [POML]    -- ^ system-level instruction fragments
    , agentMaxIterations :: Natural   -- ^ maximum ReAct iterations before giving up (must be >= 0, guaranteed by 'Natural')
    , thinkingEnabled :: Bool  -- ^ enable DeepSeek thinking mode
    }

-- | Environment capability that exposes the OpenAI client methods used by this module.
class HasAIMethods env where
    aiMethodsL :: Lens' env V1.Methods

{- | Execute a typed AI request and decode the first chat-completion response.
PRE-CONTRACT: The environment provides OpenAI methods through 'aiMethodsL', and the model returns a JSON payload matching the requested response type.
POST-CONTRACT: Returns the decoded first response when present and decodable, otherwise 'Nothing'.
-}
askAI :: (HasAIMethods env, HasGLogFunc env, GMsg env ~ AppLogMsgWithContext, HasLoggingContext env, MonadReader env m, MonadIO m, FromJSON a) => AIRequest a -> m (Maybe a)
askAI (AIRequest prompt systemPrompt _outputType thinkingEnabled) = do
    V1.Methods{V1.createChatCompletion} <- view aiMethodsL
    let
        sysMsg = Chat.System
            { content = [Chat.Text $ renderPOMLtoPrompt systemPrompt]
            , name = Nothing
            , extra = Nothing
            }
        usrMsg = Chat.User
            { content = [Chat.Text $ renderPOMLtoPrompt prompt]
            , name = Nothing
            , extra = Nothing
            }
        req = Chat._CreateChatCompletion
            { Chat.model = defaultModel
            , Chat.response_format = Just Chat.JSON_Object
            , Chat.messages = [sysMsg, usrMsg]
            , Chat.extra = thinkingExtra thinkingEnabled
            }
    Chat.ChatCompletionObject{choices} <- liftIO $ createChatCompletion req
    -- Log reasoning_content if present (DeepSeek thinking mode)
    case choices !? 0 of
        Just Chat.Choice{message} -> logReasoningContent message
        Nothing -> pure ()
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
--   parameters defaulting to @{"type": "object"}@ when absent or amended with
--   @\"type\": \"object\"@ when the generated schema lacks a top-level type.
toOpenAITool :: ToolDescription -> Tool.Tool
toOpenAITool ToolDescription{toolDescName, toolDescDescription, toolDescParameters} = Tool.Tool_Function Tool.Function
    { Tool.name = toolDescName
    , Tool.description = Just toolDescDescription
    , Tool.parameters = ensureObjectType <$> toolDescParameters <|> Just (object ["type" .= ("object" :: Text)])
    , Tool.strict = Nothing
    }

-- | Ensure a JSON Schema 'Value' has a top-level @\"type\": \"object\"@ field.
-- DeepSeek and OpenAI require tool parameter schemas to be of @type: "object"@;
-- 'toInlinedSchema' for sum types produces @oneOf@ schemas that lack this field.
ensureObjectType :: Value -> Value
ensureObjectType (Object m)
    | KM.member "type" m = Object m
    | otherwise = Object $ KM.insert "type" "object" m
ensureObjectType v = v

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
solveWithAgentLoop AgentRequest{agentPrompt, agentSystemPrompt, agentMaxIterations, thinkingEnabled} = go agentMaxIterations initialMessages
  where
    initialMessages = V.fromList
        [ Chat.System
            { content = [Chat.Text $ renderPOMLtoPrompt agentSystemPrompt]
            , name = Nothing
            , extra = Nothing
            }
        , Chat.User
            { content = [Chat.Text $ renderPOMLtoPrompt agentPrompt]
            , name = Nothing
            , extra = Nothing
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
                , Chat.extra = thinkingExtra thinkingEnabled
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
                                        logCtx <- view logContextL
                                        glog $ AppLogMsgWithContext
                                            { logMsg = SensitiveLogMsg $ "Agent tool call: " <> toolName <> " " <> argsText
                                            , logContext = logCtx
                                            , logCallSite = Nothing
                                            }
                                        result <- tryAny $ liftIO $ exec toolName argsValue
                                        let encodedResult = case result of
                                                Right v  -> encodeValueToText v
                                                Left err -> encodeValueToText $ object
                                                    [ "error" .= (fromString (displayException err) :: Text) ]
                                        glog $ AppLogMsgWithContext
                                            { logMsg = SensitiveLogMsg $ "Agent tool result: " <> toolName <> " " <> encodedResult
                                            , logContext = logCtx
                                            , logCallSite = Nothing
                                            }
                                        pure (callId, encodedResult)
                            let assistantMsg = Chat.Assistant
                                    { Chat.assistant_content = Just [Chat.Text $ Chat.messageToContent message]
                                    , Chat.refusal = Nothing
                                    , Chat.name = Nothing
                                    , Chat.assistant_audio = Nothing
                                    , Chat.tool_calls = Just tcs
                                    , Chat.extra = Chat.messageExtra message  -- preserve reasoning_content for DeepSeek thinking
                                    }
                                toolMsgs = map (\(tid, result) ->
                                    Chat.Tool { content = [Chat.Text result], tool_call_id = tid, extra = Nothing }
                                    ) toolResults
                            go (remaining - 1) (history <> V.fromList (assistantMsg : toolMsgs))
                    _ -> do
                        logReasoningContent message
                        decodeContent (Chat.messageToContent message)

    decodeContent content
        | content == "" = pure Nothing
        | otherwise = case eitherDecodeStrictText content of
            Right a -> pure (Just a)
            Left _ -> case eitherDecodeStrictText (wrapAsAgentResponse content) of
                Right a -> pure (Just a)
                Left err -> do
                    logCtx <- view logContextL
                    glog $ AppLogMsgWithContext
                        { logMsg = SensitiveLogMsg $ "Agent decode error: " <> fromString err
                        , logContext = logCtx
                        , logCallSite = Nothing
                        }
                    pure Nothing

    wrapAsAgentResponse = TL.toStrict . encodeToLazyText
