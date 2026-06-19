--   PURPOSE: Re-export the public AI scripting language so backend scripts can depend on a stable facade instead of the underlying algebra module.
--   SCOPE: Public re-exports for the AI language functor, AI request smart constructor, and script alias used by backend scripts.
--   DEPENDS: M-LIB-LANG-AI-LANG

-- | Stable facade for the AI scripting language used across backend scripts.
module LazyCircus.Scene.AI (
    AILangF (..),
    ask,
    askContinuing,
    solveWithAgent,
    solveWithAgentContinuing,
    AIScript,
    AgentRequest(..),
    Conversation,
    emptyConversation,
    -- Logging re-exports
    slogInfo,
    slogWarn,
    slogError,
    slogSensitive,
    swithLogCtx,
)
where

import LazyCircus.AI (AgentRequest(..), Conversation, emptyConversation)
import LazyCircus.Scene.AI.Lang (AILangF (..))


import LazyCircus.Scene.AI.Lang (ask)


import LazyCircus.Scene.AI.Lang (askContinuing)


import LazyCircus.Scene.AI.Lang (solveWithAgent)


import LazyCircus.Scene.AI.Lang (solveWithAgentContinuing)


import LazyCircus.Scene.AI.Lang (AIScript)


import LazyCircus.Scene.Log (slogError, slogInfo, slogSensitive, slogWarn, swithLogCtx)

