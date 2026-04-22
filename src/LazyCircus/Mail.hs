module LazyCircus.Mail where

import LazyCircus.App.Default
import Network.Mail.Mime (Address (..), Mail, simpleMail')
import Network.Mail.SMTP (sendMail', sendMailSTARTTLS')
import RIO hiding (to)
import RIO.Text.Lazy (fromStrict)

-- | Build a mail value using the sender credentials stored in the current environment.
makeMail :: (HasMailCreds env, MonadReader env m) => Address -> Text -> Text -> m Mail
makeMail to subject body = do
    creds <- view mailCredsL
    pure $ makeMail' creds to subject body

-- | Build a mail value from explicit SMTP credentials without reading the ambient environment.
makeMail' :: MailCreds -> Address -> Text -> Text -> Mail
makeMail' MailCreds{mailLogin, mailName} to subject body = simpleMail' to from subject (fromStrict body)
  where
    from =
        Address
            { addressName = if null mailName then Nothing else Just (fromString mailName)
            , addressEmail = fromString mailLogin
            }

-- | Deliver a prepared mail value through the SMTP account stored in the current environment.
sendMail :: (HasMailCreds env, MonadReader env m, MonadIO m) => Mail -> m ()
sendMail mail = do
    MailCreds
        { mailHost
        , mailPort
        , mailUseTls
        } <-
        view mailCredsL
    liftIO $
        if mailUseTls
            then sendMailSTARTTLS' mailHost (fromIntegral mailPort) mail
            else sendMail' mailHost (fromIntegral mailPort) mail
