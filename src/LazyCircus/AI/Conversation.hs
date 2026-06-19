{-# LANGUAGE DerivingStrategies #-}

-- | The 'Conversation' type — a durable transcript used to thread AI context
-- across multiple scenario runs.
--
-- PURPOSE: Give 'LazyCircus.AI' operations an explicit handle to the prior
-- conversation so a second scenario run receives a context-continuing answer
-- (the model \"remembers\" earlier turns, including tool exchanges).
module LazyCircus.AI.Conversation
    ( Conversation
    , unConversation
    , emptyConversation
    , conversationFromTurns
    ) where

import OpenAI.V1.Chat.Completions qualified as Chat
import RIO

-- | A durable transcript of an AI conversation.
--
-- Stored verbatim as OpenAI 'Chat.Message' turns so that the transcript can be
-- replayed to the provider losslessly (preserving @tool_call_id@s and tool
-- results) on the next operation.
--
-- INVARIANT: A 'Conversation' NEVER contains a 'Chat.System' message. System
-- context is ephemeral: it is re-injected from the request's @systemPrompt@ on
-- every operation. Only durable turns ('Chat.User' / 'Chat.Assistant' /
-- 'Chat.Tool') are stored here. This keeps 'ask' and 'solveWithAgent'
-- symmetric: each call prepends exactly one 'Chat.System', executes, and
-- returns a 'Conversation' that excludes it.
--
-- The 'Conversation' constructor is intentionally NOT exported: all
-- construction goes through 'emptyConversation', 'conversationFromTurns', or
-- the 'Semigroup' instance, so the invariant has a single, documented entry
-- point.
--
-- NOTE: 'Eq'/'Show' are intentionally NOT derived: the underlying
-- 'Chat.Message' (openai-2.5.3) does not provide them. Compare transcripts in
-- tests via projections (e.g. 'Chat.messageExtra', @tool_call_id@) or JSON
-- encoding instead of structural equality.
newtype Conversation = Conversation
    { unConversation :: Vector (Chat.Message (Vector Chat.Content))
        -- ^ Durable turns in replay order; NONE of the elements is a
        -- 'Chat.System' message (see the 'Conversation' invariant).
    } deriving newtype (Semigroup, Monoid)

-- | The empty conversation. Alias for 'mempty'.
emptyConversation :: Conversation
emptyConversation = mempty

-- | Build a 'Conversation' from a vector of durable turns.
--
-- PRE-CONTRACT: The given vector MUST contain no 'Chat.System' message (the
-- caller is responsible for stripping any ephemeral System before turning a
-- working message list into a transcript — e.g. the agent loop drops the single
-- leading System it injects per operation).
-- POST-CONTRACT: The returned 'Conversation' preserves the given turns in
-- order and is suitable for replay on the next operation.
conversationFromTurns :: Vector (Chat.Message (Vector Chat.Content)) -> Conversation
conversationFromTurns = Conversation
