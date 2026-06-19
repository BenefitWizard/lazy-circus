{-# LANGUAGE MultiParamTypeClasses #-}

-- | Free-monad AI effect language for typed request execution.
--
-- Each effect carries a 'LazyCircus.AI.Conversation' so a scenario can thread
-- AI context across calls. Stateless smart constructors ('ask', 'solveWithAgent')
-- are thin wrappers that inject 'LazyCircus.AI.emptyConversation' and discard the
-- resulting transcript.
--
-- NOTE (breaking): the 'Ask' and 'SolveWithAgent' constructors carry an extra
-- 'Conversation' field and a continuation of type @(Maybe b, Conversation) -> a@.
-- This is an intentional change to the exported GADT; the only internal pattern
-- match is 'LazyCircus.Scene.AI.Class.runAI'.
module LazyCircus.Scene.AI.Lang (
    AILangF (..),
    ask,
    askContinuing,
    solveWithAgent,
    solveWithAgentContinuing,
    AIScript,
) where

import Control.Monad.Free.Church (F)
import Control.Monad.Free.Church qualified as CF
import Control.Monad.Free.Class qualified as MF
import Data.Aeson (FromJSON)
import LazyCircus.AI (AIRequest, AgentRequest, Conversation, emptyConversation)
import LazyCircus.Scene.Log (HasLogLang (..), LogLangF)
import RIO hiding (ask)

liftFC :: (Functor f, MF.MonadFree f m) => f a -> m a
liftFC = CF.liftF

-- | Effect functor describing typed AI requests and logging that may decode to a result or fail with no value.
data AILangF a where
    Ask
        :: (FromJSON b)
        => AIRequest b
        -> Conversation
        -> ((Maybe b, Conversation) -> a)
        -> AILangF a
    SolveWithAgent
        :: (FromJSON b)
        => AgentRequest b
        -> Conversation
        -> ((Maybe b, Conversation) -> a)
        -> AILangF a
    AILog :: LogLangF AIScript b -> (b -> a) -> AILangF a

-- | Maps over the continuation carried by each AI effect while preserving its request payload and conversation handle.
instance Functor AILangF where
    fmap f (Ask req conv next) = Ask req conv (f . next)
    fmap f (SolveWithAgent req conv next) = SolveWithAgent req conv (f . next)
    fmap f (AILog logOp next) = AILog logOp (f . next)

-- | Enable polymorphic logging operations inside AIScript.
instance HasLogLang AILangF AIScript where
    embedLog logOp = AILog logOp id

{- | Lift a typed AI request into the AI effect language (stateless wrapper).
PRE-CONTRACT: The requested response type must provide a 'FromJSON' instance and the active interpreter must know how to execute the request.
POST-CONTRACT: Produces a program that yields 'Nothing' when the interpreter cannot decode a valid response. Discards any resulting 'Conversation'.
-}
ask :: (MF.MonadFree AILangF m, FromJSON b) => AIRequest b -> m (Maybe b)
ask request = fst <$> askContinuing request emptyConversation

{- | Lift a typed AI request that threads and returns a 'Conversation'.
PRE-CONTRACT: The requested response type must provide a 'FromJSON' instance, and the input 'Conversation' must NOT begin with a 'Chat.System' message (see the 'Conversation' invariant).
POST-CONTRACT: Produces a program that yields the decoded result (or 'Nothing') paired with the updated 'Conversation'.
-}
askContinuing :: (MF.MonadFree AILangF m, FromJSON b) => AIRequest b -> Conversation -> m (Maybe b, Conversation)
askContinuing request conv = liftFC $ Ask request conv id

{- | Lift an agent-loop request into the AI effect language (stateless wrapper).
PRE-CONTRACT: The requested response type must provide a 'FromJSON' instance and the active interpreter must support agent-loop execution.
POST-CONTRACT: Produces a program that yields 'Nothing' when the interpreter cannot complete the agent loop or decode a valid response. Discards any resulting 'Conversation'.
-}
solveWithAgent :: (MF.MonadFree AILangF m, FromJSON b) => AgentRequest b -> m (Maybe b)
solveWithAgent request = fst <$> solveWithAgentContinuing request emptyConversation

{- | Lift an agent-loop request that threads and returns a 'Conversation'.
PRE-CONTRACT: The requested response type must provide a 'FromJSON' instance, and the input 'Conversation' must NOT begin with a 'Chat.System' message.
POST-CONTRACT: Produces a program that yields the decoded result (or 'Nothing') paired with the updated 'Conversation'.
-}
solveWithAgentContinuing :: (MF.MonadFree AILangF m, FromJSON b) => AgentRequest b -> Conversation -> m (Maybe b, Conversation)
solveWithAgentContinuing request conv = liftFC $ SolveWithAgent request conv id

-- | Church-encoded free program over 'AILangF'.
type AIScript = F AILangF
