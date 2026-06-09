{-# LANGUAGE MultiParamTypeClasses #-}

-- | Free-monad AI effect language for typed request execution.
module LazyCircus.Scene.AI.Lang (
    AILangF (..),
    ask,
    solveWithAgent,
    AIScript,
) where

import Control.Monad.Free.Church (F)
import Control.Monad.Free.Church qualified as CF
import Control.Monad.Free.Class qualified as MF
import Data.Aeson (FromJSON)
import LazyCircus.AI (AIRequest, AgentRequest)
import LazyCircus.Scene.Log (HasLogLang (..), LogLangF)
import RIO hiding (ask)

liftFC :: (Functor f, MF.MonadFree f m) => f a -> m a
liftFC = CF.liftF

-- | Effect functor describing typed AI requests and logging that may decode to a result or fail with no value.
data AILangF a where
    Ask :: (FromJSON b) => AIRequest b -> (Maybe b -> a) -> AILangF a
    SolveWithAgent :: (FromJSON b) => AgentRequest b -> (Maybe b -> a) -> AILangF a
    AILog :: LogLangF AIScript b -> (b -> a) -> AILangF a

-- | Maps over the continuation carried by each AI effect while preserving its request payload.
instance Functor AILangF where
    fmap f (Ask req next) = Ask req (f . next)
    fmap f (SolveWithAgent req next) = SolveWithAgent req (f . next)
    fmap f (AILog logOp next) = AILog logOp (f . next)

-- | Enable polymorphic logging operations inside AIScript.
instance HasLogLang AILangF AIScript where
    embedLog logOp = AILog logOp id

{- | Lift a typed AI request into the AI effect language.
PRE-CONTRACT: The requested response type must provide a 'FromJSON' instance and the active interpreter must know how to execute the request.
POST-CONTRACT: Produces a program that yields 'Nothing' when the interpreter cannot decode a valid response.
-}
ask :: (MF.MonadFree AILangF m, FromJSON b) => AIRequest b -> m (Maybe b)
ask request = liftFC $ Ask request id

{- | Lift an agent-loop request into the AI effect language.
PRE-CONTRACT: The requested response type must provide a 'FromJSON' instance and the active interpreter must support agent-loop execution.
POST-CONTRACT: Produces a program that yields 'Nothing' when the interpreter cannot complete the agent loop or decode a valid response.
-}
solveWithAgent :: (MF.MonadFree AILangF m, FromJSON b) => AgentRequest b -> m (Maybe b)
solveWithAgent request = liftFC $ SolveWithAgent request id

-- | Church-encoded free program over 'AILangF'.
type AIScript = F AILangF
