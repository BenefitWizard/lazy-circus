-- | Performer capability surface and runner for the mail free language.
module LazyCircus.Scene.Mail.Class (
    MailScriptPerformer (..),
    runMail,
)
where

import Control.Monad.Free.Church (iterM)
import LazyCircus.App.Log (HasLogQueue, HasLoggingContext)
import LazyCircus.Scene.Log (handleLogLang)
import LazyCircus.Scene.Mail.Lang
import Network.Mail.Mime (Address, Mail)
import RIO

-- | Capability class for interpreting operations in the mail free language.
class (Monad m) => MailScriptPerformer m where
    sendMail' :: Mail -> m ()
    makeMail' :: Address -> Text -> Text -> m Mail

{- | Interprets a 'MailScript' by folding each algebra instruction into the provided 'MailScriptPerformer'.
PRE-CONTRACT: The target monad must provide a 'MailScriptPerformer' instance that handles every 'MailLangF' constructor,
and must also provide 'HasLogQueue' and 'HasLoggingContext' for logging support.
POST-CONTRACT: Executes the script effects in order and returns the final script result in the target monad.
-}
runMail :: (MailScriptPerformer m, HasLogQueue env, HasLoggingContext env, MonadReader env m, MonadIO m) => MailScript a -> m a
runMail = iterM go
  where
    go (SendMail mail next) = do
        sendMail' mail
        next
    go (MakeMail to subject body next) = do
        mail <- makeMail' to subject body
        next mail
    go (MailLog logOp next) = handleLogLang "Mail" runMail (fmap next logOp)
