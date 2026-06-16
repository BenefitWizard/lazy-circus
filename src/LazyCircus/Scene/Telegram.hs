--   PURPOSE: Re-export the public Telegram scripting language and interpreter surface so backend scripts can depend on a stable facade instead of the underlying modules.
--   SCOPE: Public re-exports for the Telegram interpreter typeclass, runner, algebra, smart constructors, and script alias used by control programs.
--   DEPENDS: M-LIB-LANG-TELEGRAM-CLASS, M-LIB-LANG-TELEGRAM-LANG

-- | Stable facade for the Telegram scripting language used across backend scripts.
module LazyCircus.Scene.Telegram (
  TelegramScriptPerformer (..),
  runTelegram,
  TelegramScriptF (..),
  getFile,
  getBotName,
  sendMessage,
  sendDocument,
  sendImportantMessage,
  scheduleMessage,
  scheduleMessages,
  setBotCommands,
  setMessageReaction,
  answerCallbackQuery,
  editMessageText,
  TelegramScript,
  -- Logging re-exports
  slogInfo,
  slogWarn,
  slogError,
  slogSensitive,
  swithLogCtx,
)
where

import LazyCircus.Scene.Telegram.Class (TelegramScriptPerformer (..))


import LazyCircus.Scene.Telegram.Class (runTelegram)


import LazyCircus.Scene.Telegram.Lang (TelegramScriptF (..))


import LazyCircus.Scene.Telegram.Lang (getFile)


import LazyCircus.Scene.Telegram.Lang (getBotName)


import LazyCircus.Scene.Telegram.Lang (sendMessage)


import LazyCircus.Scene.Telegram.Lang (sendDocument)


import LazyCircus.Scene.Telegram.Lang (sendImportantMessage)


import LazyCircus.Scene.Telegram.Lang (scheduleMessage)


import LazyCircus.Scene.Telegram.Lang (scheduleMessages)


import LazyCircus.Scene.Telegram.Lang (setBotCommands)


import LazyCircus.Scene.Telegram.Lang (setMessageReaction)


import LazyCircus.Scene.Telegram.Lang (answerCallbackQuery)


import LazyCircus.Scene.Telegram.Lang (editMessageText)


import LazyCircus.Scene.Telegram.Lang (TelegramScript)


import LazyCircus.Scene.Log (slogError, slogInfo, slogSensitive, slogWarn, swithLogCtx)

