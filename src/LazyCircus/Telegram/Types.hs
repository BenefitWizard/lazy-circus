module LazyCircus.Telegram.Types (
    TgEmoji(..),
    fromTgEmoji,
    BotEnv(..),
    AppWithBotEnv(..),
    TelegramClientError(..),
    NoPollInResponse(..),
    TelegramApiRejected(..),
    TelegramDownloadStatusError(..),
 ) where

import Network.HTTP.Types (Status)
import RIO
import Servant.Client hiding (Response)
import Telegram.Bot.API (Message, ReactionType (..), Response, Token)

-- | Supported Telegram emoji reactions used by bot reply helpers.
data TgEmoji
    = Note
    | ThumbUp
    | Thinking
    deriving (Show, Eq)

-- | Render supported reactions as the exact emoji text expected by Telegram.
instance Display TgEmoji where
    display Note = "✍"
    display ThumbUp = "👍"
    display Thinking = "🤔"

-- | Convert a supported emoji into Telegram's reaction payload representation.
fromTgEmoji :: TgEmoji -> ReactionType
fromTgEmoji emoji =
    ReactionTypeEmoji
        { reactionTypeEmojiType = "emoji"
        , reactionTypeEmojiEmoji = textDisplay emoji
        }

-- | Runtime bundle for one configured Telegram bot.
data BotEnv = BotEnv
    { botToken :: Token
    , botClientEnv :: ClientEnv
    , botName :: Text
    }

-- | Show only the bot name for debug output; the token inside 'botToken'
-- must never reach logs or exception text.
-- LAW: the rendered text contains no token material.
instance Show BotEnv where
    show env = "Bot Env for " <> show (botName env)

-- | Attach a concrete Telegram bot environment to an arbitrary application environment.
data AppWithBotEnv app = AppWithBotEnv
    { botEnv :: BotEnv
    , app :: app
    }

-- | Wraps a Servant ClientError for typed exception handling in Telegram operations.
newtype TelegramClientError = TelegramClientError ClientError

-- | Redacting 'Show': never renders the wrapped servant request or URL, since
-- the Telegram bot token lives inside the request path.
-- LAW: the rendered text contains no URL, path, or token material.
instance Show TelegramClientError where
    show (TelegramClientError err) = "TelegramClientError: " <> case err of
        FailureResponse _ resp -> "FailureResponse " <> show (responseStatusCode resp)
        DecodeFailure msg _ -> "DecodeFailure " <> show msg
        UnsupportedContentType ct _ -> "UnsupportedContentType " <> show ct
        InvalidContentTypeHeader _ -> "InvalidContentTypeHeader"
        ConnectionError _ -> "ConnectionError"

-- | Enables throwing and catching TelegramClientError as a typed exception.
instance Exception TelegramClientError

-- | Telegram answered successfully but the returned message carried no poll payload.
-- Carries the raw 'Response' — it contains only response data, never request URLs,
-- so the bot token cannot leak through 'Show'.
newtype NoPollInResponse = NoPollInResponse (Response Message)
    deriving (Show)

-- | Enables throwing and catching NoPollInResponse as a typed exception.
instance Exception NoPollInResponse

-- | Telegram API rejected the request: either the HTTP transport delivered a
-- non-2xx failure response (e.g. 429 rate limit, 409 conflict), or a 2xx
-- response whose @ok@ field is @false@ (seen with local Bot API servers and
-- proxies). The cause lives in the carried error code and description; a 429
-- additionally carries the server-advised @retry_after@ delay.
-- Carries only response payload fields — never request URLs, so the bot token
-- cannot leak through 'Show'.
data TelegramApiRejected = TelegramApiRejected
    { telegramApiRejectedErrorCode :: Maybe Integer -- ^ Bot API @error_code@ field, if present
    , telegramApiRejectedDescription :: Maybe Text  -- ^ Bot API @description@ field, if present
    , telegramApiRejectedRetryAfter :: Maybe Int    -- ^ @parameters.retry_after@ seconds, present on 429 responses
    }
    deriving (Show, Eq)

-- | Enables throwing and catching TelegramApiRejected as a typed exception.
instance Exception TelegramApiRejected

-- | Non-2xx HTTP status returned by the Telegram file-download endpoint.
-- Carries only the 'Status' — never the request URL, which embeds the bot token.
newtype TelegramDownloadStatusError = TelegramDownloadStatusError Status
    deriving (Show)

-- | Enables throwing and catching TelegramDownloadStatusError as a typed exception.
instance Exception TelegramDownloadStatusError
