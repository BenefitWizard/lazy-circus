{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Free-monad HTTP effect language for executing servant-client requests in backend scripts.
module LazyCircus.Scene.HTTP.Lang (
    HTTPLangF (..),
    runClient,
    HTTPScript,
) where

import Control.Monad.Free.Church (F)
import Control.Monad.Free.Church qualified as CF
import Control.Monad.Free.Class qualified as MF
import LazyCircus.Scene.Log (HasLogLang (..), LogLangF)
import RIO
import Servant.Client (ClientError, ClientM)

liftFC :: (Functor f, MF.MonadFree f m) => f a -> m a
liftFC = CF.liftF

-- | Effect functor describing servant-client request execution and logging.
data HTTPLangF a where
    RunClient :: ClientM b -> (Either ClientError b -> a) -> HTTPLangF a
    HTTPLog   :: LogLangF HTTPScript b -> (b -> a) -> HTTPLangF a

-- | Maps over the continuation carried by each HTTP effect while preserving its request payload.
instance Functor HTTPLangF where
    fmap f (RunClient act next) = RunClient act (f . next)
    fmap f (HTTPLog logOp next) = HTTPLog logOp (f . next)

-- | Enable polymorphic logging operations inside HTTPScript.
instance HasLogLang HTTPLangF HTTPScript where
    embedLog logOp = HTTPLog logOp id

-- | Lift a servant-client action into the HTTP script language.
-- PRE-CONTRACT: The provided ClientM action must be a valid servant-client request.
-- POST-CONTRACT: Produces a script that yields 'Either ClientError b' — Left for network/decode failures, Right for success.
runClient :: (MF.MonadFree HTTPLangF m) => ClientM b -> m (Either ClientError b)
runClient act = liftFC $ RunClient act id

-- | Church-encoded free program over 'HTTPLangF'.
type HTTPScript = F HTTPLangF
