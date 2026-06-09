-- | Performer capability surface and runner for the HTTP free language.
module LazyCircus.Scene.HTTP.Class (
    HTTPPerformer (..),
    runHTTP,
) where

import Control.Monad.Free.Church (iterM)
import LazyCircus.App.Log (HasLogQueue, HasLoggingContext)
import LazyCircus.Scene.HTTP.Lang
import LazyCircus.Scene.Log (handleLogLang)
import RIO
import Servant.Client (ClientError, ClientM)

-- | Capability class for interpreting operations in the HTTP free language.
class (Monad m) => HTTPPerformer m where
    runClient' :: ClientM a -> m (Either ClientError a)

-- | Interprets an 'HTTPScript' by folding each algebra instruction into the provided 'HTTPPerformer'.
-- PRE-CONTRACT: The target monad must provide an 'HTTPPerformer' instance that handles the 'RunClient' constructor,
-- and must also provide 'HasLogQueue' and 'HasLoggingContext' for logging support.
-- POST-CONTRACT: Executes the script effects in order and returns the final script result in the target monad.
runHTTP :: (HTTPPerformer m, HasLogQueue env, HasLoggingContext env, MonadReader env m, MonadIO m) => HTTPScript a -> m a
runHTTP = iterM go
  where
    go (RunClient act next) = do
        result <- runClient' act
        next result
    go (HTTPLog logOp next) = handleLogLang "HTTP" runHTTP (fmap next logOp)
