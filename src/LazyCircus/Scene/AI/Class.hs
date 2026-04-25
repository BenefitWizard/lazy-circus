-- | Performer capability surface and runner for the AI free language.
--
-- PURPOSE: Define the AILangPerformer capability class and the runAI interpreter that folds AIScript programs into a target monad.
-- SCOPE: AILangPerformer class with ask', and the runAI natural-transformation runner.
module LazyCircus.Scene.AI.Class (
  AILangPerformer (..),
  runAI,
) where

import Control.Monad.Free.Church (iterM)
import Data.Aeson (FromJSON)

import LazyCircus.AI (AIRequest)
import LazyCircus.App.Log (HasLogQueue, HasLoggingContext)
import LazyCircus.App.Service (HasToolDescriptions (..))
import LazyCircus.Scene.AI.Lang
import LazyCircus.Scene.Log (handleLogLang)
import RIO

-- | Capability class for interpreting operations in the AI free language.
class (Monad m) => AILangPerformer m where
  -- | Execute a typed AI request and return the decoded result or Nothing on failure.
  ask' :: (FromJSON b) => AIRequest b -> m (Maybe b)

{- | Interprets an 'AIScript' by folding each algebra instruction into the provided 'AILangPerformer'.
PRE-CONTRACT: The target monad must provide an 'AILangPerformer' instance that handles every 'AILangF' constructor,
and the environment must provide 'HasLogQueue', 'HasLoggingContext', and 'HasToolDescriptions'.
POST-CONTRACT: Executes the scripted AI requests in order and returns the final script result in the target monad.
-}
runAI :: (AILangPerformer m, HasLogQueue env, HasLoggingContext env, HasToolDescriptions env, MonadReader env m, MonadIO m) => AIScript a -> m a
runAI = iterM go
 where
  -- | Pattern-match each AILangF constructor and delegate to the performer or log handler.
  go (Ask request next) = do
    response <- ask' request
    next response
  go (AILog logOp next) = handleLogLang "AI" runAI (fmap next logOp)
