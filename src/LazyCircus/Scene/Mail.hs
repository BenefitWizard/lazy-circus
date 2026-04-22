--   PURPOSE: Re-export the public mail scripting language so backend scripts can depend on a stable facade instead of the underlying algebra module.
--   SCOPE: Public re-exports for the mail language functor, smart constructors, and script alias used by backend scripts.
--   DEPENDS: M-LIB-LANG-MAIL-LANG

-- | Stable facade for the mail scripting language used across backend scripts.
module LazyCircus.Scene.Mail (
    MailLangF (..),
    sendMail,
    makeMail,
    MailScript,
    -- Logging re-exports
    slogInfo,
    slogWarn,
    slogError,
    slogSensitive,
    swithLogCtx,
)
where

import LazyCircus.Scene.Mail.Lang (MailLangF (..))


import LazyCircus.Scene.Mail.Lang (sendMail)


import LazyCircus.Scene.Mail.Lang (makeMail)


import LazyCircus.Scene.Mail.Lang (MailScript)


import LazyCircus.Scene.Log (slogError, slogInfo, slogSensitive, slogWarn, swithLogCtx)

