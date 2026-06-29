{-# LANGUAGE NoImplicitPrelude #-}

{- | Telegram bot conversation-state types for Lazy Circus.

Both "ChatStateStore" and "BotHandler" depend on 'Model' and 'ChatState', so the
two conversation-state types live here rather than in either of those modules.
-}
module BotApp (
    Model (..),
    ChatState (..),
    ) where

import RIO

import LazyCircus.AI (Conversation)

-- | Per-chat conversation state for the multi-step /newact dialog and the agent busy-lock.
data ChatState
    = Idle
    | WaitingForName
    | -- | act name already received
      WaitingForDescription Text
    | -- | an agent turn is in flight; kept only as defensive code under the
      -- new per-chat serialised dispatch model (see "BotHandler" module Haddock)
      AgentBusy
    deriving (Eq, Show)

-- | Bot model holding the current chat conversation state and the durable agent transcript.
data Model = Model
    { modelChatState :: ChatState
      -- ^ current multi-step dialog state for commands like /newact
    , modelConversation :: Conversation
      -- ^ durable agent 'Conversation' threaded across messages so tool exchanges survive
    }
