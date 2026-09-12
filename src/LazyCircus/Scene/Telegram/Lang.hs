{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Free-monad Telegram effect language for backend scripts.
module LazyCircus.Scene.Telegram.Lang (
  TelegramScriptF (..),
  getFile,
  downloadFile,
  downloadFileById,
  downloadCheckedFile,
  getBotName,
  sendMessage,
  sendDocument,
  sendPoll,
  sendInvoice,
  sendImportantMessage,
  scheduleMessage,
  scheduleMessages,
  setBotCommands,
  setMessageReaction,
  answerCallbackQuery,
  answerPreCheckoutQuery,
  editMessageText,
  deleteMessage,
  TelegramScript,
) where

import Control.Monad.Free.Church
import LazyCircus.LangCode
import LazyCircus.Scene.Log (HasLogLang (..), LogLangF)
import LazyCircus.Telegram.FileCheck (FileValidationError (..), checkDownloadedBytes, checkFileSize)
import LazyCircus.Telegram.Types (WithImportance (..))
import RIO
import Telegram.Bot.API (ChatId, Message, MessageId, PollId, Response (..), SendMessageRequest, SetMessageReactionRequest)
import Telegram.Bot.API.Methods.AnswerCallbackQuery (AnswerCallbackQueryRequest)
import Telegram.Bot.API.Methods.SendDocument (SendDocumentRequest)
import Telegram.Bot.API.Methods.SendPoll (SendPollRequest)
import Telegram.Bot.API.Payments (AnswerPreCheckoutQueryRequest, SendInvoiceRequest)
import Telegram.Bot.API.Types (File (..), FileId)
import Telegram.Bot.API.UpdatingMessages (EditMessageResponse, EditMessageTextRequest)

-- | Effect functor describing Telegram file, file-download, identity, message, poll, invoice, reaction, command, callback, pre-checkout, edit, deletion, and logging operations.
data TelegramScriptF a where
  GetFile :: FileId -> (Response File -> a) -> TelegramScriptF a
  DownloadFile :: File -> (ByteString -> a) -> TelegramScriptF a
  GetBotName :: (Text -> a) -> TelegramScriptF a
  SendMessage :: (WithImportance SendMessageRequest) -> (Response Message -> a) -> TelegramScriptF a
  SendDocument :: SendDocumentRequest -> (Response Message -> a) -> TelegramScriptF a
  SendPoll :: SendPollRequest -> ((PollId, Message) -> a) -> TelegramScriptF a
  SendInvoice :: SendInvoiceRequest -> (Response Message -> a) -> TelegramScriptF a
  ScheduleMessages :: [SendMessageRequest] -> a -> TelegramScriptF a
  SetMessageReaction :: SetMessageReactionRequest -> a -> TelegramScriptF a
  SetBotCommands :: HashMap LangCode [(Text, Text)] -> a -> TelegramScriptF a
  AnswerCallbackQuery :: AnswerCallbackQueryRequest -> a -> TelegramScriptF a
  AnswerPreCheckoutQuery :: AnswerPreCheckoutQueryRequest -> a -> TelegramScriptF a
  EditMessageText :: EditMessageTextRequest -> (Maybe EditMessageResponse -> a) -> TelegramScriptF a
  DeleteMessage :: ChatId -> MessageId -> a -> TelegramScriptF a
  TgLog :: LogLangF TelegramScript b -> (b -> a) -> TelegramScriptF a

-- | Maps over Telegram-effect continuations while preserving the requested operation payloads.
instance Functor TelegramScriptF where
  fmap f (GetFile fileId next) = GetFile fileId (f . next)
  fmap f (DownloadFile file next) = DownloadFile file (f . next)
  fmap f (GetBotName next) = GetBotName (f . next)
  fmap f (SendMessage request next) = SendMessage request (f . next)
  fmap f (SendDocument req next) = SendDocument req (f . next)
  fmap f (SendPoll req next) = SendPoll req (f . next)
  fmap f (SendInvoice req next) = SendInvoice req (f . next)
  fmap f (ScheduleMessages requests next) = ScheduleMessages requests (f next)
  fmap f (SetBotCommands commands next) = SetBotCommands commands (f next)
  fmap f (SetMessageReaction request next) = SetMessageReaction request (f next)
  fmap f (AnswerCallbackQuery req next) = AnswerCallbackQuery req (f next)
  fmap f (AnswerPreCheckoutQuery req next) = AnswerPreCheckoutQuery req (f next)
  fmap f (EditMessageText req next) = EditMessageText req (f . next)
  fmap f (DeleteMessage chatId messageId next) = DeleteMessage chatId messageId (f next)
  fmap f (TgLog logOp next) = TgLog logOp (f . next)

-- | Enable polymorphic logging operations inside TelegramScript.
instance HasLogLang TelegramScriptF TelegramScript where
  embedLog logOp = TgLog logOp id

-- makeFree ''TelegramScriptF

{- | Lift Telegram file metadata lookup into the Telegram script language.
PRE-CONTRACT: The 'FileId' must identify a file accessible to the configured bot.
POST-CONTRACT: Produces a script that yields the Telegram API response returned by the interpreter.
-}
getFile :: FileId -> TelegramScript (Response File)
getFile fileId = liftF $ GetFile fileId id

{- | Lift downloading of a Telegram file's content into the Telegram script language.
The download is in-memory: the interpreter returns the raw bytes as a strict
'ByteString' and never touches the filesystem.
PRE-CONTRACT: The 'File' must originate from a prior 'getFile' call, because the
interpreter needs its @file_path@; transport errors surface as exceptions in the
performer, never as an error value.
POST-CONTRACT: Produces a script that yields the file content supplied by the interpreter.
-}
downloadFile :: File -> TelegramScript ByteString
downloadFile file = liftF $ DownloadFile file id

{- | Composite: resolve a 'FileId' to metadata via 'getFile', then download the
content of the resulting file, returning both.
The raw 'Response' of @getFile@ is handed to the scenario as-is; this composite
applies NO validation. The download is in-memory (strict 'ByteString'); the
filesystem is never touched.
PRE-CONTRACT: Transport errors of the underlying 'getFile' \/ 'downloadFile' are
exceptions, not results. In Mocked tests the returned response always carries
@responseOk = True@ (canned default response).
POST-CONTRACT: Produces a script that yields @(resp, bytes)@ where @bytes@ is
the content of @responseResult resp@.
-}
downloadFileById :: FileId -> TelegramScript (Response File, ByteString)
downloadFileById fid = do
  resp <- getFile fid
  bytes <- downloadFile (responseResult resp)
  pure (resp, bytes)

{- | Composite: size-validated variant of 'downloadFileById'.
Gate A ('checkFileSize') inspects the server-reported size BEFORE downloading
(an over-reported file is rejected without any download); gate B
('checkDownloadedBytes') inspects the actual downloaded byte length and is
authoritative. The download is in-memory (strict 'ByteString'); the filesystem
is never touched.
PRE-CONTRACT: @maxBytes@ must be non-negative. 'Left' is exclusively a
size-validation reject; transport errors of the underlying 'getFile' /
'downloadFile' remain exceptions. In Mocked tests the response of a success
always carries @responseOk = True@ (canned default response).
POST-CONTRACT: Produces a script that yields @Right (resp, bytes)@ when the file
passes both gates, or @Left 'FileSizeExceedsLimit'@ — in the gate-A case
without downloading anything.
-}
downloadCheckedFile :: Integer -> FileId -> TelegramScript (Either FileValidationError (Response File, ByteString))
downloadCheckedFile maxBytes fid = do
  resp <- getFile fid
  case checkFileSize maxBytes (fileFileSize (responseResult resp)) of
    Just err -> pure (Left err)
    Nothing -> do
      bytes <- downloadFile (responseResult resp)
      pure $ case checkDownloadedBytes maxBytes bytes of
        Left err -> Left err
        Right okBytes -> Right (resp, okBytes)

{- | Lift bot-name lookup into the Telegram script language.
PRE-CONTRACT: The interpreter must be able to provide the configured bot name.
POST-CONTRACT: Produces a script that yields the bot name text supplied by the interpreter.
-}
getBotName :: TelegramScript Text
getBotName = liftF $ GetBotName id

{- | Lift sending a regular Telegram message into the Telegram script language.
PRE-CONTRACT: The request must be valid for the configured Telegram bot and API endpoint.
POST-CONTRACT: Produces a script that yields the Telegram API response for a regular message send.
-}
sendMessage :: SendMessageRequest -> TelegramScript (Response Message)
sendMessage request = liftF $ SendMessage (Regular request) id

{- | Lift sending an importance-marked Telegram message into the Telegram script language.
PRE-CONTRACT: The request must be valid for the configured Telegram bot and any downstream importance handling.
POST-CONTRACT: Produces a script that yields the Telegram API response for an importance-marked message send.
-}
sendImportantMessage :: SendMessageRequest -> TelegramScript (Response Message)
sendImportantMessage request = liftF $ SendMessage (Important request) id

{- | Lift sending a document file via the Telegram Bot API into the Telegram script language.
PRE-CONTRACT: The request must be valid for the configured Telegram bot and API endpoint.
POST-CONTRACT: Produces a script that yields the Telegram API response for a document send.
-}
sendDocument :: SendDocumentRequest -> TelegramScript (Response Message)
sendDocument req = liftF $ SendDocument req id

{- | Lift sending a poll via the Telegram Bot API into the Telegram script language.
PRE-CONTRACT: The request must be valid for the configured Telegram bot and API endpoint.
POST-CONTRACT: Produces a script that yields the poll identifier and the message carrying the poll as supplied by the interpreter.
-}
sendPoll :: SendPollRequest -> TelegramScript (PollId, Message)
sendPoll req = liftF $ SendPoll req id

{- | Lift sending a Telegram Stars invoice into the Telegram script language.
PRE-CONTRACT: The request must carry a chat identifier the bot is allowed to invoice; for Stars payments its provider token must be empty and its currency @XTR@ (see "LazyCircus.Telegram.Stars").
POST-CONTRACT: Produces a script that yields the Telegram API response carrying the invoice message.
-}
sendInvoice :: SendInvoiceRequest -> TelegramScript (Response Message)
sendInvoice req = liftF $ SendInvoice req id

{- | Lift scheduling of a single Telegram message into the Telegram script language.
PRE-CONTRACT: The request must be valid for the interpreter's deferred-delivery queue.
POST-CONTRACT: Produces a script that schedules exactly one message and returns unit.
-}
scheduleMessage :: SendMessageRequest -> TelegramScript ()
scheduleMessage request = liftF $ ScheduleMessages [request] ()

{- | Lift scheduling of multiple Telegram messages into the Telegram script language.
PRE-CONTRACT: Each request must be valid for the interpreter's deferred-delivery queue.
POST-CONTRACT: Produces a script that schedules the provided batch in order and returns unit.
-}
scheduleMessages :: [SendMessageRequest] -> TelegramScript ()
scheduleMessages requests = liftF $ ScheduleMessages requests ()

{- | Lift localized Telegram bot command registration into the Telegram script language.
PRE-CONTRACT: Each language-code entry must contain command and description pairs accepted by the downstream Telegram API.
POST-CONTRACT: Produces a script that requests bot-command registration and returns unit.
-}
setBotCommands :: HashMap LangCode [(Text, Text)] -> TelegramScript ()
setBotCommands commands = liftF $ SetBotCommands commands ()

{- | Lift Telegram message reaction updates into the Telegram script language.
PRE-CONTRACT: The request must target a message and reaction supported by the configured bot and Telegram API.
POST-CONTRACT: Produces a script that requests the reaction update and returns unit.
-}
setMessageReaction :: SetMessageReactionRequest -> TelegramScript ()
setMessageReaction request = liftF $ SetMessageReaction request ()

{- | Lift answering a Telegram callback query into the Telegram script language.
PRE-CONTRACT: The request must contain a valid callback query identifier accepted by the Telegram API.
POST-CONTRACT: Produces a script that acknowledges the callback query and returns unit.
-}
answerCallbackQuery :: AnswerCallbackQueryRequest -> TelegramScript ()
answerCallbackQuery req = liftF $ AnswerCallbackQuery req ()

{- | Lift answering a Telegram pre-checkout query into the Telegram script language.
PRE-CONTRACT: The request must reference a pre-checkout query received from Telegram; the answer must reach Telegram within 10 seconds or the payment times out.
POST-CONTRACT: Produces a script that acknowledges the pre-checkout query and returns unit.
-}
answerPreCheckoutQuery :: AnswerPreCheckoutQueryRequest -> TelegramScript ()
answerPreCheckoutQuery req = liftF $ AnswerPreCheckoutQuery req ()

{- | Lift editing a Telegram message's text into the Telegram script language.
PRE-CONTRACT: The request must target an existing message and provide valid text content for the configured bot.
POST-CONTRACT: Produces a script that requests the message edit and returns the updated message when successful, or Nothing if the edit fails.
-}
editMessageText :: EditMessageTextRequest -> TelegramScript (Maybe EditMessageResponse)
editMessageText req = liftF $ EditMessageText req id

{- | Lift deleting a Telegram message into the Telegram script language.
Fire-and-forget: yields unit, consistent with 'setMessageReaction'.
PRE-CONTRACT: The chat and message ids must identify a message the configured bot is allowed to delete.
POST-CONTRACT: Produces a script that requests the deletion and returns unit.
-}
deleteMessage :: ChatId -> MessageId -> TelegramScript ()
deleteMessage chatId messageId = liftF $ DeleteMessage chatId messageId ()

-- | Church-encoded free program over 'TelegramScriptF'.
type TelegramScript = F TelegramScriptF
