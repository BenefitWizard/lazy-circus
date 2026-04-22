{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}

--   PURPOSE: Define the mail effect language that backend scripts use to construct email messages and request delivery without binding to a concrete mail implementation.
--   SCOPE: Mail effect constructors, smart constructors for message creation and delivery, and the church-encoded script alias used by control programs.
--   DEPENDS: none

-- | Free-monad mail effect language for composing and sending email in backend scripts.
module LazyCircus.Scene.Mail.Lang (
    MailLangF (..),
    sendMail,
    makeMail,
    MailScript,
) where

import Control.Monad.Free.Church (F)
import Control.Monad.Free.Church qualified as CF
import Control.Monad.Free.Class qualified as MF
import LazyCircus.Scene.Log (HasLogLang (..), LogLangF)
import Network.Mail.Mime (Address, Mail)
import RIO

liftFC :: (Functor f, MF.MonadFree f m) => f a -> m a
liftFC = CF.liftF


-- | Effect functor describing mail delivery, construction, and logging operations.
data MailLangF a where
    SendMail :: Mail -> a -> MailLangF a
    MakeMail :: Address -> Text -> Text -> (Mail -> a) -> MailLangF a
    MailLog :: LogLangF MailScript b -> (b -> a) -> MailLangF a



-- | Maps over mail-effect continuations while preserving the requested mail operation.
instance Functor MailLangF where
    fmap f (SendMail mail next) = SendMail mail (f next)
    fmap f (MakeMail to subject body next) = MakeMail to subject body (f . next)
    fmap f (MailLog logOp next) = MailLog logOp (f . next)



-- | Enable polymorphic logging operations inside MailScript.
instance HasLogLang MailLangF MailScript where
    embedLog logOp = MailLog logOp id



{- | Lift a mail delivery request into the mail script language.
PRE-CONTRACT: The provided 'Mail' value must already contain the content and addressing required by the downstream interpreter.
POST-CONTRACT: Produces a script that requests delivery and returns unit when the interpreter continues.
-}
sendMail :: (MF.MonadFree MailLangF m) => Mail -> m ()
sendMail mail = liftFC $ SendMail mail ()



{- | Lift a mail construction request into the mail script language.
PRE-CONTRACT: The address, subject, and body must be valid for the configured mail backend.
POST-CONTRACT: Produces a script that returns the materialized 'Mail' value supplied by the interpreter.
-}
makeMail :: (MF.MonadFree MailLangF m) => Address -> Text -> Text -> m Mail
makeMail to subject body = liftFC $ MakeMail to subject body id



-- | Church-encoded free program over 'MailLangF'.
type MailScript = F MailLangF

