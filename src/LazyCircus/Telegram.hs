{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}

module LazyCircus.Telegram where

-- import Lib.Telegram.Types (HasTgMessageQueue (..))
-- import Lib.Telegram.Types qualified as TGTypes
-- import Network.HTTP.Conduit (Manager)
import Network.HTTP.Types (Status (..), statusIsSuccessful)
import RIO
import RIO.HashMap qualified as Map
import RIO.Text qualified as Text

import LazyCircus.Telegram.Types

-- import Servant

import Data.Aeson
import LazyCircus.App.Log
import LazyCircus.LangCode
import LazyCircus.Telegram.Default
import LazyCircus.Telegram.Types qualified as TGTypes
import Network.HTTP.Client hiding (Proxy, responseBody)
import Network.HTTP.Client qualified as Http.Client
import Servant.Client hiding (Response (..))
import Servant.Client as SC (Response (..), ResponseF (..))
import Telegram.Bot.API as TGAPI (ChatId, File (..), FileId, MessageId, Response (..), Token, botBaseUrl)
import Telegram.Bot.API qualified as TGAPI
import Telegram.Bot.API.Methods (SendMessageRequest)
import Telegram.Bot.API.Methods.AnswerCallbackQuery (AnswerCallbackQueryRequest)
import Telegram.Bot.API.Methods.SendDocument (SendDocumentRequest)
import Telegram.Bot.API.UpdatingMessages (EditMessageResponse, EditMessageTextRequest)

-- https://api.telegram.org/file/bot<token>/<file_path>

-- | Base URL of the Telegram file-download endpoint: the bot API base URL
-- with a @/file@ path segment inserted.
fileBaseUrlFromBotBaseUrl :: BaseUrl -> BaseUrl
fileBaseUrlFromBotBaseUrl (BaseUrl scheme host port path) = BaseUrl scheme host port newPath
  where
    newPath = "/file" <> path

-- | Full download URL for a Telegram-issued @file_path@, embedded VERBATIM
-- (no percent-encoding: the path is server-issued and already URL-shaped).
-- PRE-CONTRACT: filePath comes from a Telegram @getFile@ response.
-- POST-CONTRACT: Result is @<file-base-url>/<file_path>@ with the path unescaped.
fileDownloadUrl :: BaseUrl -> Text -> Text
fileDownloadUrl botBase filePath =
    Text.pack (showBaseUrl (fileBaseUrlFromBotBaseUrl botBase)) <> "/" <> filePath

-- | Environment capability that exposes the Telegram Servant client environment.
class HasTgClientEnv env where
    tgClientEnvL :: Lens' env ClientEnv

instance HasTgClientEnv (AppWithBotEnv app) where
    tgClientEnvL = lens (botClientEnv . botEnv) (\x y -> let be = botEnv x in x{botEnv = be{botClientEnv = y}})

instance (HasLogQueue app) => HasLogQueue (AppWithBotEnv app) where
    logQueueL = lens app (\x y -> x{app = y}) . logQueueL

instance (HasLoggingContext app) => HasLoggingContext (AppWithBotEnv app) where
    logContextL = lens app (\x y -> x{app = y}) . logContextL

-- | Internal environment capability used by bot-name helpers in this facade.
class HasBotName env where
    botNameL :: Lens' env Text

instance HasBotName (AppWithBotEnv app) where
    botNameL = lens (botName . botEnv) (\x y -> let be = botEnv x in x{botEnv = be{botName = y}})

-- | Build a bot environment with a Telegram client, configured bot name, and deferred message queue.
makeBotEnv :: Manager -> (Token, Text) -> IO BotEnv
makeBotEnv manager (token, name) = do
    queue <- newTQueueIO
    pure
        BotEnv
            { botToken = token
            , botClientEnv = makeClientEnv manager token
            , botName = name
            , botMessageQueue = queue
            }

makeClientEnv :: Manager -> Token -> ClientEnv
makeClientEnv manager token = mkClientEnv manager (botBaseUrl token)

sendMessage ::
    ( HasTgClientEnv env
    , MonadIO m
    , MonadReader env m
    , HasTgMessageQueue env
    ) =>
    TGTypes.WithImportance SendMessageRequest -> m (TGAPI.Response TGAPI.Message)
sendMessage (TGTypes.Regular req) = do
    clientEnv <- view tgClientEnvL
    mv <- liftIO $ runClientM (TGAPI.sendMessage req) clientEnv
    case mv of
        Left err -> handleClientError err
        Right v -> pure v
sendMessage (TGTypes.Important req) = do
    clientEnv <- view tgClientEnvL
    mv <- liftIO $ runClientM (TGAPI.sendMessage req) clientEnv
    case mv of
        Left err -> handleTooManyRequests req err >>= handleClientError
        Right v -> pure v

-- | Fetch Telegram file metadata for a previously received file identifier.
getFile :: (HasTgClientEnv env, MonadIO m, MonadReader env m) => FileId -> m (TGAPI.Response File)
getFile fileId = do
    clientEnv <- view tgClientEnvL
    mv <- liftIO $ runClientM (TGAPI.getFile fileId) clientEnv
    case mv of
        Left err -> throwIO (TGTypes.TelegramClientError err)
        Right v -> pure v

{- | Download the content of a Telegram 'File' previously obtained via 'getFile'.

The request reuses the bot's shared HTTP manager (TLS settings and connection
pool) from the client environment, but is issued through http-client directly:
servant's @Capture@ would percent-encode the @/@ separators in the
server-issued @file_path@ (e.g. @documents%2Ffile_10.pdf@), which Telegram
rejects — 'fileDownloadUrl' embeds the path verbatim instead.

The bytes are returned in memory as a strict 'ByteString'; the filesystem is
never touched. Persistence (DB or disk) is the scenario's responsibility.
Keeping the payload in memory is safe because the Bot API caps file downloads
at 20 MiB.
PRE-CONTRACT: The 'File' must come from a prior 'getFile' call — its
@file_path@ must be populated. A missing path is an internal contract violation
and throws. Transport failures throw, mirroring 'getFile'.
POST-CONTRACT: Returns the raw file content bytes.
-}
downloadFile :: (HasTgClientEnv env, MonadIO m, MonadReader env m) => File -> m ByteString
downloadFile file = do
    clientEnv <- view tgClientEnvL
    filePath <- case fileFilePath file of
        Just path -> pure path
        Nothing -> throwString "LazyCircus.Telegram.downloadFile: File has no file_path; it must come from a getFile response"
    request <-
        liftIO . Http.Client.parseRequest . Text.unpack $
            fileDownloadUrl (baseUrl clientEnv) filePath
    response <- liftIO $ Http.Client.httpLbs request (manager clientEnv)
    let status = Http.Client.responseStatus response
    unless (statusIsSuccessful status) $
        throwIO (TGTypes.TelegramDownloadStatusError status)
    pure (toStrictBytes (Http.Client.responseBody response))

-- | Read the configured Telegram bot name from the current environment.
getBotName :: (HasBotName env, MonadReader env m) => m Text
getBotName = do
    botName <- view botNameL
    pure botName

setMessageReaction ::
    ( HasTgClientEnv env
    , MonadIO m
    , MonadReader env m
    ) =>
    TGAPI.SetMessageReactionRequest -> m ()
setMessageReaction req = do
    clientEnv <- view tgClientEnvL
    mv <- liftIO $ runClientM (TGAPI.setMessageReaction req) clientEnv
    case mv of
        Left err -> throwIO (TGTypes.TelegramClientError err)
        Right _v -> pure ()

-- | Delete a message in a chat via the Telegram Bot API.
-- Fire-and-forget: mirrors 'setMessageReaction' (unit result, transport errors throw).
-- Transport failures throw 'TGTypes.TelegramClientError' — never stringified:
-- rendering the underlying 'ClientError' would leak the token-bearing request URL.
-- PRE-CONTRACT: The chat and message ids must identify a message the bot is allowed to delete.
-- POST-CONTRACT: Returns unit; a transport failure throws.
deleteMessage ::
    ( HasTgClientEnv env
    , MonadIO m
    , MonadReader env m
    ) =>
    ChatId -> MessageId -> m ()
deleteMessage chatId messageId = do
    clientEnv <- view tgClientEnvL
    mv <- liftIO $ runClientM (TGAPI.deleteMessage chatId messageId) clientEnv
    case mv of
        Left err -> throwIO (TGTypes.TelegramClientError err)
        Right _v -> pure ()

scheduleMessages ::
    ( MonadIO m
    , MonadReader env m
    , HasTgMessageQueue env
    ) =>
    [SendMessageRequest] -> m ()
scheduleMessages requests = do
    mq <- view tgMessageQueueL
    atomically $ mapM_ (writeTQueue mq) requests

setBotCommands ::
    ( HasBotName env
    , HasTgClientEnv env
    , MonadIO m
    , MonadReader env m
    ) =>
    HashMap LangCode [(Text, Text)] -> m ()
setBotCommands commands = do
    -- botName <- getBotName
    clientEnv <- view tgClientEnvL
    let reqs =
            Map.map (TGAPI.defSetMyCommands . map botCommandFromPair) commands
                & Map.toList
                & map (\(langCode, setCommandRequest) -> setCommandRequest{TGAPI.setMyCommandsLanguageCode = toMaybeText langCode})
    forM_ reqs $ \setCommandRequest -> do
        mv <- liftIO $ runClientM (TGAPI.setMyCommands setCommandRequest) clientEnv
        case mv of
            Left err -> throwIO (TGTypes.TelegramClientError err)
            Right _ -> pure ()
  where
    botCommandFromPair (command, description) =
        TGAPI.BotCommand command description

answerCallbackQuery ::
    ( HasTgClientEnv env
    , MonadIO m
    , MonadReader env m
    ) =>
    AnswerCallbackQueryRequest -> m ()
answerCallbackQuery req = do
    clientEnv <- view tgClientEnvL
    mv <- liftIO $ runClientM (TGAPI.answerCallbackQuery req) clientEnv
    case mv of
        Left err -> throwIO (TGTypes.TelegramClientError err)
        Right _v -> pure ()

editMessageText ::
    ( HasTgClientEnv env
    , MonadIO m
    , MonadReader env m
    ) =>
    EditMessageTextRequest -> m (Maybe EditMessageResponse)
editMessageText req = do
    clientEnv <- view tgClientEnvL
    mv <- liftIO $ runClientM (TGAPI.editMessageText req) clientEnv
    case mv of
        Left _err -> pure Nothing
        Right v -> pure $ Just (TGAPI.responseResult v)

-- | Send a document file via the Telegram Bot API.
-- PRE-CONTRACT: The request must contain a valid chat identifier and an accessible document source.
-- POST-CONTRACT: Returns the Telegram API response for the document send.
sendDocument ::
    ( HasTgClientEnv env
    , MonadIO m
    , MonadReader env m
    ) =>
    SendDocumentRequest -> m (TGAPI.Response TGAPI.Message)
sendDocument req = do
    clientEnv <- view tgClientEnvL
    mv <- liftIO $ runClientM (TGAPI.sendDocument req) clientEnv
    case mv of
        Left err -> handleClientError err
        Right v -> pure v

-- glog $ AppLogMsg $ "Setting commands for bot " <> botName

-- Error handling

handleTooManyRequests ::
    (MonadIO m, HasTgMessageQueue env, MonadReader env m) =>
    TGAPI.SendMessageRequest -> ClientError -> m ClientError
handleTooManyRequests originalRequest err@(FailureResponse _ r) = case r of
    -- too many requests, we can schedule the message for later
    SC.Response{responseStatusCode = Status{statusCode = 429}} -> do
        scheduleMessages [originalRequest]
        pure err
    _ -> pure err
handleTooManyRequests _ err = pure err

handleClientError :: (MonadIO m) => ClientError -> m (TGAPI.Response TGAPI.Message)
handleClientError err@(FailureResponse _ r) = case r of
    -- bad parsing of our message, we can log and ignore it
    -- should be never occur on production
    SC.Response{responseStatusCode = Status{statusCode = 409}} ->
        pure $ defaultResponse (Just 409) defaultMessage
    -- too many requests
    -- it was scheduled for later if was needed
    -- we can return default response with 429 status code
    SC.Response{responseStatusCode = Status{statusCode = 429}, responseBody = body} ->
        let mResponse = decode body
         in pure $ fromMaybe (defaultResponse (Just 429) defaultMessage) mResponse
    -- unknown shit happens, lets crash
    _ -> throwIO (TGTypes.TelegramClientError err)
handleClientError err = throwIO (TGTypes.TelegramClientError err)
