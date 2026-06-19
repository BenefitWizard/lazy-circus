-- | Performer capability surface and runner for the AI free language.
--
-- PURPOSE: Define the AILangPerformer capability class and the runAI interpreter that folds AIScript programs into a target monad.
-- SCOPE: AILangPerformer class with continuing primitives and stateless defaults, plus the runAI natural-transformation runner.
module LazyCircus.Scene.AI.Class (
  AILangPerformer (..),
  runAI,
) where

import Control.Monad.Free.Church (iterM)
import Data.Aeson (FromJSON)

import LazyCircus.AI (AIRequest, AgentRequest, Conversation, emptyConversation)
import LazyCircus.App.Log (HasLogQueue, HasLoggingContext)
import LazyCircus.App.Service (HasToolDescriptions (..))
import LazyCircus.Scene.AI.Lang
import LazyCircus.Scene.Log (handleLogLang)
import RIO

-- | Capability class for interpreting operations in the AI free language.
--
-- The continuing operations ('askContinuing'', 'solveWithAgentContinuing'') are
-- the primitives; the stateless operations ('ask'', 'solveWithAgent'') have
-- default implementations that inject 'emptyConversation' and discard the
-- resulting transcript, preserving the legacy behaviour.
class (Monad m, MonadUnliftIO m) => AILangPerformer m where
  {-# MINIMAL askContinuing' #-}
  -- | Execute a typed AI request that threads and returns a 'Conversation'.
  askContinuing' :: (FromJSON b) => AIRequest b -> Conversation -> m (Maybe b, Conversation)
  -- | Execute an agent-loop AI request that threads and returns a 'Conversation'.
  --   Default returns 'Nothing' and leaves the conversation unchanged (no agent support).
  solveWithAgentContinuing' :: (FromJSON b) => AgentRequest b -> Conversation -> m (Maybe b, Conversation)
  solveWithAgentContinuing' _ conv = pure (Nothing, conv)

  -- | Stateless wrapper around 'askContinuing''. Discards the resulting 'Conversation'.
  ask' :: (FromJSON b) => AIRequest b -> m (Maybe b)
  ask' req = fst <$> askContinuing' req emptyConversation

  -- | Stateless wrapper around 'solveWithAgentContinuing''. Discards the resulting 'Conversation'.
  solveWithAgent' :: (FromJSON b) => AgentRequest b -> m (Maybe b)
  solveWithAgent' req = fst <$> solveWithAgentContinuing' req emptyConversation

{- | Interprets an 'AIScript' by folding each algebra instruction into the provided 'AILangPerformer'.
PRE-CONTRACT: The target monad must provide an 'AILangPerformer' instance that handles every 'AILangF' constructor,
and the environment must provide 'HasLogQueue', 'HasLoggingContext', and 'HasToolDescriptions'.
POST-CONTRACT: Executes the scripted AI requests in order and returns the final script result in the target monad.
-}
runAI :: (AILangPerformer m, HasLogQueue env, HasLoggingContext env, HasToolDescriptions env, MonadReader env m, MonadIO m) => AIScript a -> m a
runAI = iterM go
 where
  -- | Pattern-match each AILangF constructor and delegate to the performer or log handler.
  go (Ask request conv next) = do
    response <- askContinuing' request conv
    next response
  go (SolveWithAgent request conv next) = do
    response <- solveWithAgentContinuing' request conv
    next response
  go (AILog logOp next) = handleLogLang "AI" runAI (fmap next logOp)
