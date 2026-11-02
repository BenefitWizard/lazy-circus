{-# LANGUAGE OverloadedStrings #-}

{- | Unit tests for the reply-aware stateful update builder
(LazyCircus.Testing.Updates.mkReplyUpdateByUser): the produced update's
@reply_to_message@ must reference the supplied target 'MessageId' with the
sender and text intact, while the plain sibling 'mkTextUpdateByUser' must
carry NO @reply_to_message@ — that difference is what a \"reply to another
message is ignored\" scenario hangs on. Pure factory arithmetic, no app, no
PostgreSQL.
-}
module LazyCircus.Testing.UpdatesSpec (spec) where

import RIO
import Test.Hspec

import LazyCircus.Testing.Updates
    ( defaultTestChatId
    , defaultTestUserId
    , mkReplyUpdateByUser
    , mkTextUpdateByUser
    , newUpdateFactory
    )
import Telegram.Bot.API
    ( ChatId (..)
    , UserId (..)
    , chatId
    , messageChat
    , messageFrom
    , messageMessageId
    , messageReplyToMessage
    , messageText
    , updateMessage
    , userId
    )
import Telegram.Bot.API.Types (MessageId (..))

spec :: Spec
spec = do
    factory <- runIO newUpdateFactory
    describe "mkReplyUpdateByUser (reply_to_message stub)" $ do
        it "references the supplied target message id with sender and text intact" $ do
            upd <- mkReplyUpdateByUser factory defaultTestUserId defaultTestChatId (MessageId 42) "+@olga"
            let Just msg = updateMessage upd
            (messageMessageId <$> messageReplyToMessage msg)
                `shouldBe` Just (MessageId 42)
            messageText msg `shouldBe` Just "+@olga"
            (userId <$> messageFrom msg) `shouldBe` Just defaultTestUserId

        it "mirrors the chat in the reply_to_message stub" $ do
            upd <- mkReplyUpdateByUser factory defaultTestUserId defaultTestChatId (MessageId 7) "-@bob"
            let Just msg = updateMessage upd
            (chatId . messageChat <$> messageReplyToMessage msg)
                `shouldBe` Just defaultTestChatId

        it "keeps two replies to the same target distinguishable by update id" $ do
            upd1 <- mkReplyUpdateByUser factory defaultTestUserId defaultTestChatId (MessageId 42) "+@olga"
            upd2 <- mkReplyUpdateByUser factory defaultTestUserId defaultTestChatId (MessageId 42) "+@olga"
            -- both target the same message; the carrier messages stay distinct
            let carrierId upd = messageMessageId <$> updateMessage upd
            carrierId upd1 `shouldSatisfy` (\m1 -> m1 /= carrierId upd2)

    describe "mkTextUpdateByUser (the non-reply baseline)" $ do
        it "carries no reply_to_message" $ do
            upd <- mkTextUpdateByUser factory defaultTestUserId defaultTestChatId "just a message"
            let Just msg = updateMessage upd
            -- Message has no Eq; pinning absence through an Eq field of the stub
            (messageMessageId <$> messageReplyToMessage msg) `shouldBe` Nothing

        -- pins the UserId accessor round trip the reply test above relies on
        it "sets the sender" $ do
            upd <- mkTextUpdateByUser factory (UserId 2007) (ChatId 3) "hi"
            let Just msg = updateMessage upd
            (userId <$> messageFrom msg) `shouldBe` Just (UserId 2007)
