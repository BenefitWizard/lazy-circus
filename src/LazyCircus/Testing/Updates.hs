{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Helpers for constructing fake Telegram 'Update's in tests.
--
-- Two flavours are provided:
--
-- 1. /Pure/ builders ('mkTextUpdate', 'mkNonTextMessageUpdate') that hardcode
--    @update_id = 0@ and chat id @1@. Convenient for single-shot, synchronous
--    handler tests where update identity is irrelevant.
-- 2. A /stateful/ 'UpdateFactory' that hands out monotonically increasing
--    @update_id@ values, plus @*ByUser@ variants that target an explicit user
--    and chat. These back the @tgTest@ runner ('LazyCircus.Testing.TgTest'),
--    where successive fake updates must be distinguishable (Telegram never
--    reuses an @update_id@ within one @getUpdates@ session, and
--    'Telegram.Bot.Extra.Polling.nextOffset' relies on the maximum @update_id@
--    to advance the offset).
module LazyCircus.Testing.Updates (
    -- * Pure builders (fixed update_id)
    mkTextUpdate,
    mkNonTextMessageUpdate,
    -- * Stateful factory
    UpdateFactory,
    newUpdateFactory,
    nextUpdateId,
    -- * Stateful builders (incremental update_id)
    mkTextUpdateByUser,
    mkTextUpdateIn,
    mkFileUpdate,
    mkDocumentUpdate,
    mkCallbackQueryUpdate,
    -- * Document helpers
    mkDocument,
    -- * Defaults
    defaultTestUserId,
    defaultTestChatId,
    ) where

import Data.Aeson (Value (Object), fromJSON, object, (.=))
import Data.Aeson.Types (Result (..))
import RIO
import Telegram.Bot.API (ChatId (..), Update, UserId (..))
import Telegram.Bot.API.Types (Document (..), FileId (..), MessageId (..))

-- | Build a minimal 'Update' carrying a single text message in a private chat.
-- Used to exercise command routing and dialog logic without a live Telegram connection.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Returns a valid 'Update' with the given text in chat id 1, or
-- 'error' if the constructed JSON fails to parse (which would indicate a bug in
-- this helper, not in the caller).
mkTextUpdate :: Text -> Update
mkTextUpdate txt = case fromJSON jsonVal of
    Success u -> u
    Error err -> error $ "mkTextUpdate: failed to parse Update: " <> err
  where
    jsonVal = Object $ mconcat
        [ "update_id" .= (0 :: Int)
        , "message" .= object
            [ "message_id" .= (1 :: Int)
            , "date" .= (0 :: Int)
            , "chat" .= object ["id" .= (1 :: Int), "type" .= ("private" :: Text)]
            , "text" .= txt
            ]
        ]

-- | Build an 'Update' carrying a message with NO text field (e.g. a sticker or
-- location), in a private chat. Used to exercise the no-op branch of handlers
-- that ignore non-text messages.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Returns a valid 'Update' whose @message@ has no @text@, or
-- 'error' if the constructed JSON fails to parse.
mkNonTextMessageUpdate :: Update
mkNonTextMessageUpdate = case fromJSON jsonVal of
    Success u -> u
    Error err -> error $ "mkNonTextMessageUpdate: failed to parse Update: " <> err
  where
    jsonVal = Object $ mconcat
        [ "update_id" .= (0 :: Int)
        , "message" .= object
            [ "message_id" .= (1 :: Int)
            , "date" .= (0 :: Int)
            , "chat" .= object ["id" .= (1 :: Int), "type" .= ("private" :: Text)]
            ]
        ]

-- | Default sender used by the stateless 'sendMessage' DSL op when no explicit
-- 'UserId' is supplied. A plausible non-bot user id.
defaultTestUserId :: UserId
defaultTestUserId = UserId 1001

-- | Default chat the stateless DSL ops target. Replies issued by the bot land
-- in this chat and are filtered back to the same 'ChatId' by the mailbox.
defaultTestChatId :: ChatId
defaultTestChatId = ChatId 1

-- | Stateful builder that hands out monotonically increasing @update_id@ values.
--
-- Each 'UpdateFactory' is a single 'IORef' counter. 'atomicModifyIORef'' ensures
-- every allocated id is unique, which is all the @tgTest@ runner requires.
newtype UpdateFactory = UpdateFactory (IORef Int)

-- | Allocate a fresh factory whose first assigned @update_id@ is @1@.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Successive 'nextUpdateId' calls return strictly increasing values.
newUpdateFactory :: IO UpdateFactory
newUpdateFactory = UpdateFactory <$> newIORef 1

-- | Allocate and return the next @update_id@ from the factory.
-- POST-CONTRACT: No two calls on the same factory return the same value.
nextUpdateId :: UpdateFactory -> IO Int
nextUpdateId (UpdateFactory ref) = atomicModifyIORef' ref (\n -> (n + 1, n))

-- | Build a text-message 'Update' from a specific user in a specific chat.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Returns a valid 'Update' with a fresh @update_id@, or 'error'
-- if the constructed JSON fails to parse (a bug in this helper).
mkTextUpdateByUser :: UpdateFactory -> UserId -> ChatId -> Text -> IO Update
mkTextUpdateByUser factory userId chatId txt =
    buildUpdate factory $ \uid ->
        textMessagePayload uid userId chatId txt

-- | Build a text-message 'Update' in a specific chat from the 'defaultTestUserId'.
mkTextUpdateIn :: UpdateFactory -> ChatId -> Text -> IO Update
mkTextUpdateIn factory chatId txt =
    mkTextUpdateByUser factory defaultTestUserId chatId txt

-- | Build a document-message 'Update' (a file upload) from a specific user/chat,
-- carrying ONLY the file id (no client-declared metadata). The metadata-free
-- sibling of 'mkDocumentUpdate'; see there when a scenario pre-checks
-- @file_name@ / @mime_type@ / @file_size@.
-- PRE-CONTRACT: 'FileId' should be a plausible non-empty identifier.
-- POST-CONTRACT: Returns a valid 'Update' whose @message.document.file_id@
-- equals the supplied 'FileId' and whose metadata fields are all 'Nothing', or
-- 'error' on parse failure.
mkFileUpdate :: UpdateFactory -> UserId -> ChatId -> FileId -> IO Update
mkFileUpdate factory userId chatId fid =
    mkDocumentUpdate factory userId chatId (mkDocument fid)

-- | A minimal 'Document' for the given 'FileId': @file_unique_id@ mirrors the
-- id and every client-declared metadata field (name, MIME type, size, thumbnail)
-- is 'Nothing'. Attach metadata via record update:
--
-- > (mkDocument (FileId "doc-1")){documentFileName = Just "report.pdf"}
mkDocument :: FileId -> Document
mkDocument fid =
    Document
        { documentFileId = fid
        , documentFileUniqueId = fid
        , documentThumbnail = Nothing
        , documentFileName = Nothing
        , documentMimeType = Nothing
        , documentFileSize = Nothing
        }

-- | Build a document-message 'Update' (a file upload) from a specific user/chat,
-- carrying the FULL 'Document' — including the client-declared @file_name@ /
-- @mime_type@ / @file_size@ metadata that scenario-level pre-checks (format or
-- size gates reading 'Document' fields) consume. The metadata is the sender's
-- claim and may disagree with the staged canned download (spoofing is testable
-- that way).
-- PRE-CONTRACT: 'documentThumbnail' is ignored — test updates never carry one.
-- POST-CONTRACT: Returns a valid 'Update' whose @message.document@ id and
-- metadata fields equal the supplied 'Document''s, or 'error' on parse failure.
mkDocumentUpdate :: UpdateFactory -> UserId -> ChatId -> Document -> IO Update
mkDocumentUpdate factory userId chatId doc =
    buildUpdate factory $ \uid ->
        fileMessagePayload uid userId chatId doc

-- | Build a @callback_query@ 'Update' from a specific user/chat, referencing the
-- given 'MessageId' (the message the inline keyboard is attached to) and
-- carrying the supplied callback data.
-- PRE-CONTRACT: 'msgId' must identify a message the bot previously sent in
-- @chatId@; the produced callback's @message@ mirrors those fields so that
-- 'answerCallbackQuery' dispatch can resolve the chat.
-- POST-CONTRACT: Returns a valid 'Update' whose @callback_query.data@ equals the
-- supplied payload, or 'error' on parse failure.
mkCallbackQueryUpdate :: UpdateFactory -> UserId -> ChatId -> MessageId -> Text -> IO Update
mkCallbackQueryUpdate factory userId chatId (MessageId msgIdNum) cbData =
    buildUpdate factory $ \uid ->
        callbackQueryPayload uid userId chatId msgIdNum cbData

-- | Internal: allocate the next update_id and parse the constructed payload.
buildUpdate :: UpdateFactory -> (Int -> Value) -> IO Update
buildUpdate factory mkPayload = do
    uid <- nextUpdateId factory
    case fromJSON (mkPayload uid) of
        Success u -> pure u
        Error err -> error $ "buildUpdate: failed to parse Update: " <> err

-- | JSON for a private-chat text message wrapped in an 'Update'.
textMessagePayload :: Int -> UserId -> ChatId -> Text -> Value
textMessagePayload uid (UserId userNum) (ChatId chatNum) txt =
    Object $ mconcat
        [ "update_id" .= uid
        , "message" .= object
            [ "message_id" .= uid
            , "date" .= (0 :: Int)
            , "from" .= userObject userNum
            , "chat" .= chatObject chatNum
            , "text" .= txt
            ]
        ]

-- | JSON for a private-chat document message wrapped in an 'Update'. The
-- document object preserves the client-declared metadata; absent fields are
-- omitted (Telegram omits optional fields rather than sending nulls).
fileMessagePayload :: Int -> UserId -> ChatId -> Document -> Value
fileMessagePayload uid (UserId userNum) (ChatId chatNum) doc =
    Object $ mconcat
        [ "update_id" .= uid
        , "message" .= object
            [ "message_id" .= uid
            , "date" .= (0 :: Int)
            , "from" .= userObject userNum
            , "chat" .= chatObject chatNum
            , "document" .= documentObject doc
            ]
        ]

-- | JSON object for a 'Document', preserving the client-declared metadata.
documentObject :: Document -> Value
documentObject Document{..} =
    object $
        [ "file_id" .= fileIdText documentFileId
        , "file_unique_id" .= fileIdText documentFileUniqueId
        ]
            <> catMaybes
                [ ("file_name" .=) <$> documentFileName
                , ("mime_type" .=) <$> documentMimeType
                , ("file_size" .=) <$> documentFileSize
                ]

-- | Underlying text of a 'FileId' (a newtype over 'Text').
fileIdText :: FileId -> Text
fileIdText (FileId txt) = txt

-- | JSON for a callback_query wrapped in an 'Update', referencing a prior message.
-- Includes the @chat_instance@ field required by 'CallbackQuery' so the payload
-- parses.
callbackQueryPayload :: Int -> UserId -> ChatId -> Integer -> Text -> Value
callbackQueryPayload uid (UserId userNum) (ChatId chatNum) msgIdNum cbData =
    Object $ mconcat
        [ "update_id" .= uid
        , "callback_query" .= object
            [ "id" .= ("cbq_" <> tshow uid :: Text)
            , "from" .= userObject userNum
            , "chat_instance" .= (tshow uid :: Text)
            , "message" .= object
                [ "message_id" .= msgIdNum
                , "date" .= (0 :: Int)
                , "chat" .= chatObject chatNum
                , "text" .= ("" :: Text)
                ]
            , "data" .= cbData
            ]
        ]

-- | JSON object for a minimal non-bot sender.
userObject :: Integer -> Value
userObject userNum =
    object
        [ "id" .= userNum
        , "is_bot" .= False
        , "first_name" .= ("Tester" :: Text)
        ]

-- | JSON object for a private chat with the given numeric id.
chatObject :: Integer -> Value
chatObject chatNum =
    object
        [ "id" .= chatNum
        , "type" .= ("private" :: Text)
        ]
