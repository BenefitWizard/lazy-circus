module LazyCircus.Telegram.Types (
    TgEmoji(..),
    fromTgEmoji,
    WithImportance(..),
    BotEnv(..),
    AppWithBotEnv(..),
    HasTgMessageQueue(..),
    TelegramClientError(..),
) where

import RIO
import Servant.Client hiding (Response)
import Telegram.Bot.API (ReactionType (..), Token)

import Telegram.Bot.API.Methods (SendMessageRequest)

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

-- | Mark deferred Telegram send requests so downstream code can distinguish priority.
data WithImportance a
    = Regular a
    | Important a

-- | Runtime bundle for one configured Telegram bot and its deferred message queue.
data BotEnv = BotEnv
    { botToken :: Token
    , botClientEnv :: ClientEnv
    , botName :: Text
    , botMessageQueue :: TQueue SendMessageRequest
    }

-- | Show only identifying bot information for debug output.
instance Show BotEnv where
    show env = "Bot Env for " <> show (botToken env)

-- | Attach a concrete Telegram bot environment to an arbitrary application environment.
data AppWithBotEnv app = AppWithBotEnv
    { botEnv :: BotEnv
    , app :: app
    }

-- | Capability class that exposes the deferred Telegram send-message queue from an environment.
class HasTgMessageQueue env where
    tgMessageQueueL :: Lens' env (TQueue SendMessageRequest)

instance HasTgMessageQueue (AppWithBotEnv app) where
    tgMessageQueueL = lens (botMessageQueue . botEnv) (\x y -> let be = botEnv x in x{botEnv = be{botMessageQueue = y}})

-- | Wraps a Servant ClientError for typed exception handling in Telegram operations.
newtype TelegramClientError = TelegramClientError ClientError
    deriving (Show)

-- | Enables throwing and catching TelegramClientError as a typed exception.
instance Exception TelegramClientError
