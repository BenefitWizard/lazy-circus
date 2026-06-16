-- | Performer capability surface and runner for the Telegram free language.
module LazyCircus.Scene.Telegram.Class (
  TelegramScriptPerformer (..),
  runTelegram,
) where

import Control.Monad.Free.Church (iterM)
import LazyCircus.App.Log (HasLogQueue, HasLoggingContext)
import LazyCircus.LangCode
import LazyCircus.Scene.Log (handleLogLang)
import LazyCircus.Scene.Telegram.Lang
import LazyCircus.Telegram.Types (WithImportance)
import RIO
import Telegram.Bot.API (Response, SendMessageRequest, SetMessageReactionRequest)
import Telegram.Bot.API.Methods.AnswerCallbackQuery (AnswerCallbackQueryRequest)
import Telegram.Bot.API.Methods.SendDocument (SendDocumentRequest)
import Telegram.Bot.API.Types (File, FileId, Message)
import Telegram.Bot.API.UpdatingMessages (EditMessageResponse, EditMessageTextRequest)

-- | Capability class for interpreting operations in the Telegram free language.
class (Monad m) => TelegramScriptPerformer m where
  getFile' :: FileId -> m (Response File)

  -- downloadFile' :: File -> m RawServiceAccount
  getBotName' :: m Text
  sendMessage' :: WithImportance SendMessageRequest -> m (Response Message)
  sendDocument' :: SendDocumentRequest -> m (Response Message)
  scheduleMessages' :: [SendMessageRequest] -> m ()
  setBotCommands' :: HashMap LangCode [(Text, Text)] -> m ()
  setMessageReaction' :: SetMessageReactionRequest -> m ()
  answerCallbackQuery' :: AnswerCallbackQueryRequest -> m ()
  editMessageText' :: EditMessageTextRequest -> m (Maybe EditMessageResponse)

{- | Interprets a 'TelegramScript' by folding each algebra instruction into the provided 'TelegramScriptPerformer'.
PRE-CONTRACT: The target monad must provide a 'TelegramScriptPerformer' instance that handles every 'TelegramScriptF' constructor,
and must also provide 'HasLogQueue', 'HasLoggingContext', 'MonadReader', and 'MonadIO' for logging support via 'handleLogLang'.
POST-CONTRACT: Executes the script effects in order, handling 'TgLog' via 'handleLogLang', and returns the final script result in the target monad.
-}
runTelegram :: (TelegramScriptPerformer m, HasLogQueue env, HasLoggingContext env, MonadReader env m, MonadIO m) => TelegramScript a -> m a
runTelegram = iterM go
 where
  go (GetFile fileId next) = do
    file <- getFile' fileId
    next file
  -- go (DownloadFile file next) = do
  --   content <- downloadFile' file
  --   next content
  go (GetBotName next) = do
    name <- getBotName'
    next name
  go (SendMessage request next) = do
    response <- sendMessage' request
    next response
  go (SendDocument req next) = do
    resp <- sendDocument' req
    next resp
  go (ScheduleMessages requests next) = do
    scheduleMessages' requests
    next
  go (SetBotCommands commands next) = do
    setBotCommands' commands
    next
  go (SetMessageReaction request next) = do
    setMessageReaction' request
    next
  go (AnswerCallbackQuery req next) = do
    answerCallbackQuery' req
    next
  go (EditMessageText req next) = do
    result <- editMessageText' req
    next result
  go (TgLog logOp next) = handleLogLang "Telegram" runTelegram (fmap next logOp)
