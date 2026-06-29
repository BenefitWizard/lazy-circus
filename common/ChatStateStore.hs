{-# LANGUAGE NoImplicitPrelude #-}

{- | In-memory, thread-safe store of per-chat FSM state.

The production bot dispatches each Telegram update to its own thread
(fire-and-forget), so two updates of the /same/ chat may be processed
concurrently. The per-chat 'Model' therefore cannot live in a local variable;
it must be held in shared state that serialises updates for a single chat while
allowing different chats to proceed in parallel.

This module provides exactly that: a 'ChatStateStore' holds a 'Model' per
'ChatId' and exposes 'withChatState', which runs an action against a chat's
'Model' under per-chat mutual exclusion.
-}
module ChatStateStore (
    ChatStateStore,
    newChatStateStore,
    withChatState,
    ) where

import RIO
import RIO.HashMap qualified as HashMap

import Telegram.Bot.API (ChatId)

import BotApp (ChatState (..), Model (..))
import LazyCircus.AI (emptyConversation)

-- | Opaque handle holding the per-chat FSM registry.
--
-- Under the hood this is a @'TVar' ('HashMap' 'ChatId' ('MVar' 'Model'))@: a single
-- lightweight registry maps each 'ChatId' to its own 'MVar'. The registry
-- 'TVar' is only touched briefly (lookup-or-insert) under 'atomically', while
-- the per-chat 'MVar' is the actual lock that serialises updates for one chat.
-- Two updates of /different/ chats touch different 'MVar's and therefore do not
-- block each other.
data ChatStateStore = ChatStateStore
    { chatStateStoreRegistry :: TVar (HashMap ChatId (MVar Model))
    }

-- | The model used for a chat the store has never seen before.
initialModel :: Model
initialModel = Model Idle emptyConversation

{- | Create an empty 'ChatStateStore'.
PRE-CONTRACT: None.
POST-CONTRACT: The returned store holds no per-chat state and is safe to share
across threads.
-}
newChatStateStore :: IO ChatStateStore
newChatStateStore = ChatStateStore <$> newTVarIO HashMap.empty

{- | Run an action against the 'Model' of a given chat and persist the result.

Looks up the 'Model' for the given 'ChatId'; on first contact the
'initialModel' (@'Model' 'Idle' 'emptyConversation'@) is used. The action
receives the current model and returns the new model together with an arbitrary
result value; the new model is stored back and the result is returned.

PRE-CONTRACT: None.
POST-CONTRACT:
  * /Per-chat mutual exclusion/: updates for a single 'ChatId' are serialised.
    A second 'withChatState' for the same chat blocks until the first has
    written back its new model, so it always observes the freshly updated model
    (no lost updates, the 'AgentBusy' lock cannot be clobbered).
  * /Cross-chat concurrency/: updates for distinct 'ChatId's are not serialised
    against each other and may run concurrently.
  * /Exception safety/: if the action throws, the chat's stored model is left
    unchanged (the original model is restored) and the exception is re-raised.
    A failing update never empties or corrupts the per-chat state.
-}
withChatState :: ChatStateStore -> ChatId -> (Model -> IO (Model, a)) -> IO a
withChatState store chatId action = do
    mvar <- getChatMVar (chatStateStoreRegistry store) chatId
    modifyMVar mvar action

-- | Look up (or atomically register) the per-chat 'MVar'.
--
-- A fresh 'MVar' is created optimistically in 'IO', then the registry is read
-- and updated under a single 'atomically' block: if a 'MVar' for this 'ChatId'
-- is already present it is reused (the optimistic one is discarded), otherwise
-- the fresh one is inserted. Because the lookup-or-insert is a single STM
-- transaction, every concurrent caller for the same 'ChatId' converges on the
-- same 'MVar'.
getChatMVar :: TVar (HashMap ChatId (MVar Model)) -> ChatId -> IO (MVar Model)
getChatMVar registry chatId = do
    fresh <- newMVar initialModel
    atomically $ do
        m <- readTVar registry
        case HashMap.lookup chatId m of
            Just existing -> pure existing
            Nothing -> do
                writeTVar registry (HashMap.insert chatId fresh m)
                pure fresh
