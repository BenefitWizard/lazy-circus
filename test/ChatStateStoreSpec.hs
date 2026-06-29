{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the per-chat FSM store ('ChatStateStore').
-- Verifies atomic read-modify-write, initial-state seeding, cross-chat
-- independence, and — critically — that concurrent updates of the SAME chat
-- are serialised so no state is lost (the property the production bot's
-- fire-and-forget dispatch relies on).
module ChatStateStoreSpec (spec) where

import RIO
import Test.Hspec

import BotApp (ChatState (..), Model (..))
import ChatStateStore (ChatStateStore, newChatStateStore, withChatState)
import LazyCircus.AI (emptyConversation)
import Telegram.Bot.API (ChatId (..))

-- | An initial idle model, matching 'ChatStateStore.initialModel'.
idleModel :: Model
idleModel = Model Idle emptyConversation

spec :: Spec
spec = do
    describe "ChatStateStore" $ do
        it "seeds an unseen chat with the initial Idle model" $ do
            store <- newChatStateStore
            observed <- withChatState store (ChatId 1) (\m -> pure (m, modelChatState m))
            observed `shouldBe` Idle

        it "persists the model returned by the action" $ do
            store <- newChatStateStore
            _ <- withChatState store (ChatId 1) (\m -> pure (m{modelChatState = WaitingForName}, ()))
            observed <- withChatState store (ChatId 1) (\m -> pure (m, modelChatState m))
            observed `shouldBe` WaitingForName

        it "keeps distinct chats independent" $ do
            store <- newChatStateStore
            _ <- withChatState store (ChatId 1) (\m -> pure (m{modelChatState = WaitingForName}, ()))
            _ <- withChatState store (ChatId 2) (\m -> pure (m{modelChatState = AgentBusy}, ()))
            s1 <- withChatState store (ChatId 1) (\m -> pure (m, modelChatState m))
            s2 <- withChatState store (ChatId 2) (\m -> pure (m, modelChatState m))
            s1 `shouldBe` WaitingForName
            s2 `shouldBe` AgentBusy

        it "serialises concurrent updates of the same chat (no lost state)" $ do
            -- Each action advances the FSM one step: Idle -> WaitingForName ->
            -- WaitingForDescription "done". Run the SAME action twice concurrently.
            -- Under correct per-chat serialisation the two runs compose into the
            -- full chain regardless of ordering, ending in "done". Without
            -- serialisation both would read Idle and both write WaitingForName,
            -- leaving the chain incomplete (a detectable lost update).
            store <- newChatStateStore
            let advance m = case modelChatState m of
                    Idle -> m{modelChatState = WaitingForName}
                    WaitingForName -> m{modelChatState = WaitingForDescription "done"}
                    _ -> m
                action m = do
                    -- Widen the read-modify-write window so a missing lock would
                    -- reliably interleave the two updates.
                    threadDelay 20000
                    pure (advance m, ())
            concurrently_
                (withChatState store (ChatId 1) action)
                (withChatState store (ChatId 1) action)
            finalState <- withChatState store (ChatId 1) (\m -> pure (m, modelChatState m))
            finalState `shouldBe` WaitingForDescription "done"
