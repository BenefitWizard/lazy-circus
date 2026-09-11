{-# LANGUAGE NoImplicitPrelude #-}

{- | In-memory, thread-safe registry correlating sent Telegram polls to chats.

A @poll_answer@ update carries a @PollId@ but NO chat id, so a bot that reacts
to votes needs to remember which chat each poll was sent to. This module
provides exactly that: a 'PollRegistry' maps the inner 'Text' of a 'PollId' to
the 'ChatId' the poll was sent to.

Keys are the inner 'Text' of 'PollId' (never 'PollId' itself) because
@PollId@ has no 'Hashable' or 'Ord' instance in @telegram-bot-api@.
-}
module PollRegistry (
    PollRegistry,
    newPollRegistry,
    registerPoll,
    registerPollSTM,
    lookupPollChat,
    lookupPollChatSTM,
    ) where

import RIO
import RIO.HashMap qualified as HashMap

import Telegram.Bot.API (ChatId, PollId (..))

-- | Opaque handle holding the poll-to-chat registry.
--
-- Under the hood this is a @'TVar' ('HashMap' 'Text' 'ChatId')@: a single
-- lightweight map touched only briefly under 'atomically'. Entries are written
-- once per sent poll and read on every @poll_answer@ update.
data PollRegistry = PollRegistry
    { pollRegistryMap :: TVar (HashMap Text ChatId)
      -- ^ poll-id text → chat the poll was sent to
    }

{- | Create an empty 'PollRegistry'.
PRE-CONTRACT: None.
POST-CONTRACT: The returned registry holds no entries and is safe to share
across threads.
-}
newPollRegistry :: IO PollRegistry
newPollRegistry = PollRegistry <$> newTVarIO HashMap.empty

{- | Record which chat a poll was sent to.
PRE-CONTRACT: None.
POST-CONTRACT: A later 'lookupPollChat' for the same 'PollId' returns this
chat; re-registering an existing poll id overwrites its previous mapping.
-}
registerPoll :: PollRegistry -> PollId -> ChatId -> IO ()
registerPoll registry pollId chatId =
    atomically (registerPollSTM registry pollId chatId)

-- | STM core of 'registerPoll'.
registerPollSTM :: PollRegistry -> PollId -> ChatId -> STM ()
registerPollSTM registry (PollId pollIdText) chatId = do
    m <- readTVar (pollRegistryMap registry)
    writeTVar (pollRegistryMap registry) (HashMap.insert pollIdText chatId m)

{- | Look up the chat a poll was sent to.
PRE-CONTRACT: None.
POST-CONTRACT: Returns 'Just' the chat registered by 'registerPoll' for this
'PollId', or 'Nothing' for a poll this process never sent (the registry is
in-memory only and does not survive a restart).
-}
lookupPollChat :: PollRegistry -> PollId -> IO (Maybe ChatId)
lookupPollChat registry pollId = atomically (lookupPollChatSTM registry pollId)

-- | STM core of 'lookupPollChat'.
lookupPollChatSTM :: PollRegistry -> PollId -> STM (Maybe ChatId)
lookupPollChatSTM registry (PollId pollIdText) =
    HashMap.lookup pollIdText <$> readTVar (pollRegistryMap registry)
