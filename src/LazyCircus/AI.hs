{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
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
    , Conversation
    , HasAIMethods(..)
    , askAI
    , askAIContinuing
    , conversationFromTurns
    , emptyConversation
    , solveWithAgentLoop
    , solveWithAgentLoopContinuing
    , unConversation
    ) where

import Data.Aeson (FromJSON, Object, Value (Object, String), eitherDecodeStrictText, object, (.=))
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Text (encodeToLazyText)
import qualified Data.Text.Lazy as TL (toStrict)
import LazyCircus.AI.Conversation (Conversation, conversationFromTurns, emptyConversation, unConversation)
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

-- | Convert a response 'Chat.Message' (whose @content@ is plain 'Text') into a
-- request-style message (whose @content@ is a 'Vector' of 'Chat.Content')
-- suitable for durable storage in a 'Conversation' and lossless replay.
--
-- A chat-completion @choice.message@ carries its text as 'Text', while request
-- messages and 'Conversation' turns use @'Vector' 'Chat.Content'@; this wraps
-- each textual content as a single 'Chat.Text' part and preserves every other
-- field (@tool_calls@, @refusal@, @extra@, etc.).
-- PRE-CONTRACT: The input is a 'Chat.Message' obtained from a completion
--   response choice (its @content@ type is 'Text').
-- POST-CONTRACT: The returned message has the same constructor and fields,
--   with each textual @content@ lifted into @'Vector' 'Chat.Content'@.
toDurableMessage :: Chat.Message Text -> Chat.Message (Vector Chat.Content)
toDurableMessage = \case
    Chat.System content name extra ->
        Chat.System (V.singleton (Chat.Text content)) name extra
    Chat.User content name extra ->
        Chat.User (V.singleton (Chat.Text content)) name extra
    Chat.Assistant assistant_content refusal name assistant_audio tool_calls extra ->
        Chat.Assistant
            (fmap (V.singleton . Chat.Text) assistant_content)
            refusal
            name
            assistant_audio
            tool_calls
            extra
    Chat.Tool content tool_call_id extra ->
        Chat.Tool (V.singleton (Chat.Text content)) tool_call_id extra

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
POST-CONTRACT: Returns the decoded first response when present and decodable, otherwise 'Nothing'. This is the stateless wrapper over 'askAIContinuing'; it discards the resulting 'Conversation'.
-}
askAI :: (HasAIMethods env, HasGLogFunc env, GMsg env ~ AppLogMsgWithContext, HasLoggingContext env, MonadReader env m, MonadIO m, FromJSON a) => AIRequest a -> m (Maybe a)
askAI req = fst <$> askAIContinuing req emptyConversation

{- | Execute a typed AI request, threading and returning a 'Conversation'.
PRE-CONTRACT: The input 'Conversation' does NOT begin with a 'Chat.System' message (see the 'Conversation' invariant). The environment provides OpenAI methods through 'aiMethodsL'.
POST-CONTRACT: Returns the decoded first response and an updated 'Conversation' that appends the assistant's reply (when a choice exists). The returned 'Conversation' does NOT contain a leading 'Chat.System'.
-}
askAIContinuing :: (HasAIMethods env, HasGLogFunc env, GMsg env ~ AppLogMsgWithContext, HasLoggingContext env, MonadReader env m, MonadIO m, FromJSON a) => AIRequest a -> Conversation -> m (Maybe a, Conversation)
askAIContinuing (AIRequest prompt systemPrompt _outputType thinkingEnabled) conv = do
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
        messages = V.cons sysMsg (unConversation conv <> V.singleton usrMsg)
        req = Chat._CreateChatCompletion
            { Chat.model = defaultModel
            , Chat.response_format = Just Chat.JSON_Object
            , Chat.messages = messages
            , Chat.extra = thinkingExtra thinkingEnabled
            }
    Chat.ChatCompletionObject{choices} <- liftIO $ createChatCompletion req
    -- Log reasoning_content if present (DeepSeek thinking mode)
    case choices !? 0 of
        Just Chat.Choice{message} -> logReasoningContent message
        Nothing -> pure ()
    -- Determine the assistant message (if any) for the transcript.
    -- The user turn of THIS operation and the assistant reply are both appended
    -- to the conversation so the next operation sees the full exchange (the
    -- assistant turn is appended regardless of decode success — the model
    -- answered — so continuity is never lost).
    -- A response choice carries a 'Message' whose content is plain 'Text'; we
    -- convert it into a request-style message via 'toDurableMessage' so it can
    -- be replayed losslessly on the next operation.
    let originalMsg = fmap (\Chat.Choice{message} -> message) (choices !? 0)
        durableMsg = fmap toDurableMessage originalMsg
        -- The new durable turns: always the user turn, plus the assistant reply
        -- when a choice exists.
        newTurns = V.singleton usrMsg <> maybe V.empty V.singleton durableMsg
        conv' = conv <> conversationFromTurns newTurns
        rawContent = Chat.messageToContent <$> originalMsg
        decoded = eitherDecodeStrictText <$> rawContent
    logCtx <- view logContextL
    result <- case decoded of
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
    pure (result, conv')

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
--   within the iteration budget, otherwise 'Nothing'. This is the stateless
--   wrapper over 'solveWithAgentLoopContinuing'; it discards the resulting
--   'Conversation'.
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
solveWithAgentLoop req = fst <$> solveWithAgentLoopContinuing req emptyConversation

{- | Run a multi-turn agent loop with tool use, threading and returning a 'Conversation'.
PRE-CONTRACT: The input 'Conversation' does NOT begin with a 'Chat.System' message. The single leading System message injected on entry is stripped from the returned 'Conversation' via 'V.drop 1'.
POST-CONTRACT: Returns the decoded final response and a 'Conversation' containing all durable turns (replayed + new). When the loop is exhausted or the API returns no choice, the returned 'Conversation' still reflects the turns exchanged so far (minus the leading System).
-}
solveWithAgentLoopContinuing ::
    ( HasAIMethods env
    , HasToolDescriptions env
    , HasToolCallExec env
    , HasGLogFunc env
    , GMsg env ~ AppLogMsgWithContext
    , HasLoggingContext env
    , MonadReader env m
    , MonadUnliftIO m
    , FromJSON b
    ) => AgentRequest b -> Conversation -> m (Maybe b, Conversation)
solveWithAgentLoopContinuing AgentRequest{agentPrompt, agentSystemPrompt, agentMaxIterations, thinkingEnabled} conv = do
    (result, finalHistory) <- go agentMaxIterations initialMessages
    pure (result, conversationFromTurns (V.drop 1 finalHistory))
  where
    initialMessages = V.cons sysMsg (unConversation conv <> V.singleton usrMsg)
    sysMsg = Chat.System
        { content = [Chat.Text $ renderPOMLtoPrompt agentSystemPrompt]
        , name = Nothing
        , extra = Nothing
        }
    usrMsg = Chat.User
        { content = [Chat.Text $ renderPOMLtoPrompt agentPrompt]
        , name = Nothing
        , extra = Nothing
        }

    go 0 history = pure (Nothing, history)
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
            Nothing -> pure (Nothing, history)
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
                        r <- decodeContent (Chat.messageToContent message)
                        -- Append the final assistant turn so the transcript stays
                        -- complete for continuity: the model's reply is itself a
                        -- durable turn that the next operation must replay.
                        pure (r, history <> V.singleton (toDurableMessage message))

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
