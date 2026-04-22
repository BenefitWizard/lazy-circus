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
module LazyCircus.AI where

import Data.Aeson (FromJSON, eitherDecodeStrictText)
import LazyCircus.AI.POML (renderPOMLtoPrompt)
import LazyCircus.AI.POML.Types (POML)
import LazyCircus.App.Log (AppLogMsg (SensitiveLogMsg), AppLogMsgWithContext (..), HasLoggingContext, logContextL)
import OpenAI.V1 qualified as V1
import OpenAI.V1.Chat.Completions qualified as Chat
import RIO
import RIO.Vector ((!?))

-- data Model = DeepSeek deriving (Show, Eq)

-- | Request payload for a structured AI completion.
data AIRequest a = AIRequest
    { prompt :: [POML]       -- ^ user-facing prompt fragments
    , systemPrompt :: [POML] -- ^ system-level instruction fragments
    , outputType :: Proxy a  -- ^ phantom proxy guiding JSON decode target
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
                { Chat.model = "deepseek-chat"
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
