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
    , AIParams(..)
    , Chat.ReasoningEffort(..)
    , mkAIRequest
    , mkAgentRequest
    , withModel
    , withTemperature
    , withTopP
    , withMaxCompletionTokens
    , withSeed
    , withFrequencyPenalty
    , withPresencePenalty
    , withStop
    , withUser
    , withReasoningEffort
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
import OpenAI.V1.Models qualified as Models (Model (..))
import OpenAI.V1.Tool qualified as Tool
import OpenAI.V1.ToolCall qualified as TC
import RIO
import RIO.Vector ((!?))
import qualified RIO.Vector as V

-- data Model = DeepSeek deriving (Show, Eq)

-- | Configurable OpenAI chat-completion parameters exposed at the request level.
--
-- Every field is 'Maybe': 'Nothing' keeps the default request behaviour, 'Just'
-- overrides the corresponding field of the built 'Chat.CreateChatCompletion'.
-- Build fragments with the @with*@ smart constructors and combine them with
-- @<>@ / 'mappend' (right operand wins, see the 'Semigroup' instance).
data AIParams = AIParams
    { aiModel               :: Maybe Text                 -- ^ model name; 'Nothing' falls back to 'defaultModel'
    , aiTemperature         :: Maybe Double               -- ^ sampling temperature
    , aiTopP                :: Maybe Double               -- ^ nucleus sampling cutoff
    , aiMaxCompletionTokens :: Maybe Natural              -- ^ completion length budget
    , aiSeed                :: Maybe Integer              -- ^ deterministic-sampling seed
    , aiFrequencyPenalty    :: Maybe Double               -- ^ penalty for repeated tokens
    , aiPresencePenalty     :: Maybe Double               -- ^ penalty encouraging new topics
    , aiStop                :: Maybe [Text]               -- ^ stop sequences (up to 4, API-side limit)
    , aiUser                :: Maybe Text                 -- ^ end-user identifier for abuse tracking
    , aiReasoningEffort     :: Maybe Chat.ReasoningEffort -- ^ reasoning depth for reasoning models
    }
    deriving (Show)

-- | Right-biased merge of parameter fragments.
-- LAW: identity: @p <> mempty = mempty <> p = p@.
-- LAW: right bias: a 'Just' field of the right operand wins over the left
--   operand's value; fields combine pointwise and are never concatenated
--   (important for 'aiStop', which overrides rather than appends).
instance Semigroup AIParams where
    l <> r = AIParams
        { aiModel = aiModel r <|> aiModel l
        , aiTemperature = aiTemperature r <|> aiTemperature l
        , aiTopP = aiTopP r <|> aiTopP l
        , aiMaxCompletionTokens = aiMaxCompletionTokens r <|> aiMaxCompletionTokens l
        , aiSeed = aiSeed r <|> aiSeed l
        , aiFrequencyPenalty = aiFrequencyPenalty r <|> aiFrequencyPenalty l
        , aiPresencePenalty = aiPresencePenalty r <|> aiPresencePenalty l
        , aiStop = aiStop r <|> aiStop l
        , aiUser = aiUser r <|> aiUser l
        , aiReasoningEffort = aiReasoningEffort r <|> aiReasoningEffort l
        }

-- | All fields 'Nothing' — keeps the default request behaviour.
-- LAW: identity holds via the 'Semigroup' instance: @x <> mempty = x@ and
--   @mempty <> x = x@.
instance Monoid AIParams where
    mempty = AIParams
        { aiModel = Nothing
        , aiTemperature = Nothing
        , aiTopP = Nothing
        , aiMaxCompletionTokens = Nothing
        , aiSeed = Nothing
        , aiFrequencyPenalty = Nothing
        , aiPresencePenalty = Nothing
        , aiStop = Nothing
        , aiUser = Nothing
        , aiReasoningEffort = Nothing
        }

-- | Single-field fragment: model name override.
-- POST-CONTRACT: All other fields are 'Nothing'.
withModel :: Text -> AIParams
withModel v = mempty{aiModel = Just v}

-- | Single-field fragment: sampling temperature override.
-- POST-CONTRACT: All other fields are 'Nothing'.
withTemperature :: Double -> AIParams
withTemperature v = mempty{aiTemperature = Just v}

-- | Single-field fragment: nucleus sampling cutoff override.
-- POST-CONTRACT: All other fields are 'Nothing'.
withTopP :: Double -> AIParams
withTopP v = mempty{aiTopP = Just v}

-- | Single-field fragment: completion length budget override.
-- POST-CONTRACT: All other fields are 'Nothing'.
withMaxCompletionTokens :: Natural -> AIParams
withMaxCompletionTokens v = mempty{aiMaxCompletionTokens = Just v}

-- | Single-field fragment: deterministic-sampling seed override.
-- POST-CONTRACT: All other fields are 'Nothing'.
withSeed :: Integer -> AIParams
withSeed v = mempty{aiSeed = Just v}

-- | Single-field fragment: repeated-token penalty override.
-- POST-CONTRACT: All other fields are 'Nothing'.
withFrequencyPenalty :: Double -> AIParams
withFrequencyPenalty v = mempty{aiFrequencyPenalty = Just v}

-- | Single-field fragment: new-topic penalty override.
-- POST-CONTRACT: All other fields are 'Nothing'.
withPresencePenalty :: Double -> AIParams
withPresencePenalty v = mempty{aiPresencePenalty = Just v}

-- | Single-field fragment: stop sequences override.
-- POST-CONTRACT: All other fields are 'Nothing'.
withStop :: [Text] -> AIParams
withStop v = mempty{aiStop = Just v}

-- | Single-field fragment: end-user identifier override.
-- POST-CONTRACT: All other fields are 'Nothing'.
withUser :: Text -> AIParams
withUser v = mempty{aiUser = Just v}

-- | Single-field fragment: reasoning depth override.
-- POST-CONTRACT: All other fields are 'Nothing'.
withReasoningEffort :: Chat.ReasoningEffort -> AIParams
withReasoningEffort v = mempty{aiReasoningEffort = Just v}

-- | Request payload for a structured AI completion.
data AIRequest a = AIRequest
    { prompt :: [POML]       -- ^ user-facing prompt fragments
    , systemPrompt :: [POML] -- ^ system-level instruction fragments
    , outputType :: Proxy a  -- ^ phantom proxy guiding JSON decode target
    , thinkingEnabled :: Bool  -- ^ enable DeepSeek thinking mode
    , requestParams :: AIParams -- ^ OpenAI parameters overlay; 'mempty' keeps defaults
    }

-- | Smart constructor for 'AIRequest' with default behaviour.
-- POST-CONTRACT: @thinkingEnabled = False@ and @requestParams = mempty@;
--   override either via record update.
mkAIRequest :: [POML] -> [POML] -> AIRequest a
mkAIRequest prompt systemPrompt =
    AIRequest
        { prompt
        , systemPrompt
        , outputType = Proxy
        , thinkingEnabled = False
        , requestParams = mempty
        }

-- | Default model used for AI completions.
defaultModel :: Models.Model
defaultModel = "deepseek-v4-flash"

-- | Construct the DeepSeek thinking extra object.
-- DeepSeek enables thinking by default when the field is absent, so BOTH cases
-- are sent explicitly: 'True' -> @{"thinking": {"type": "enabled"}}@, 'False'
-- -> @{"thinking": {"type": "disabled"}}@. Returning 'Nothing' for 'False'
-- would leave thinking ON by default and generate large 'reasoning_content'.
-- POST-CONTRACT: Always returns 'Just'; the "thinking" type is "enabled" or "disabled".
thinkingExtra :: Bool -> Maybe Object
thinkingExtra True  = Just $ KM.fromList [("thinking", object ["type" .= ("enabled" :: Text)])]
thinkingExtra False = Just $ KM.fromList [("thinking", object ["type" .= ("disabled" :: Text)])]

-- | Overlay 'AIParams' on a base chat-completion request.
-- POST-CONTRACT: Every 'Just' field replaces the base value; every 'Nothing'
--   field resets to the API default ('Nothing'). 'aiModel' falls back to the
--   base model. Fields not covered by 'AIParams' (messages, response_format,
--   tools, tool_choice, extra, …) pass through untouched.
applyParams :: AIParams -> Chat.CreateChatCompletion -> Chat.CreateChatCompletion
applyParams params base = base
    { Chat.model = maybe (baseModelOf base) Models.Model (aiModel params)
    , Chat.temperature = aiTemperature params
    , Chat.top_p = aiTopP params
    , Chat.max_completion_tokens = aiMaxCompletionTokens params
    , Chat.seed = aiSeed params
    , Chat.frequency_penalty = aiFrequencyPenalty params
    , Chat.presence_penalty = aiPresencePenalty params
    , Chat.stop = V.fromList <$> aiStop params
    , Chat.user = aiUser params
    , Chat.reasoning_effort = aiReasoningEffort params
    }

-- | Read the model of a chat-completion request.
-- A record pattern is used because 'DuplicateRecordFields' makes the qualified
-- selector @Chat.model@ ambiguous (@ChatCompletionObject@ has a field of the
-- same name).
baseModelOf :: Chat.CreateChatCompletion -> Models.Model
baseModelOf Chat.CreateChatCompletion{Chat.model = m} = m

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
    , agentParams :: AIParams -- ^ OpenAI parameters overlay; 'mempty' keeps defaults
    }

-- | Smart constructor for 'AgentRequest' with default behaviour.
-- POST-CONTRACT: @thinkingEnabled = False@ and @agentParams = mempty@;
--   override either via record update.
mkAgentRequest :: [POML] -> [POML] -> Natural -> AgentRequest a
mkAgentRequest agentPrompt agentSystemPrompt agentMaxIterations =
    AgentRequest
        { agentPrompt
        , agentSystemPrompt
        , agentMaxIterations
        , thinkingEnabled = False
        , agentParams = mempty
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
askAIContinuing (AIRequest prompt systemPrompt _outputType thinkingEnabled requestParams) conv = do
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
        req = applyParams requestParams $ Chat._CreateChatCompletion
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
solveWithAgentLoopContinuing AgentRequest{agentPrompt, agentSystemPrompt, agentMaxIterations, thinkingEnabled, agentParams} conv = do
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
            req = applyParams agentParams $ Chat._CreateChatCompletion
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
