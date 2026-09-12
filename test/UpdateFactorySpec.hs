{-# LANGUAGE OverloadedStrings #-}

{- | T8 completion spec: the 'LazyCircus.Testing.Updates' generators build valid
'Telegram.Bot.API.Update' values with monotonically increasing @update_id@,
carrying the requested chat, user, message id, and callback data.

These are pure-ish IO tests: no 'DefaultApp' or PostgreSQL is required.
-}
module UpdateFactorySpec (spec) where

import RIO
import Test.Hspec

import Telegram.Bot.API
    ( ChatId (..)
    , UserId (..)
    , callbackQueryData
    , callbackQueryMessage
    , chatId
    , documentFileId
    , documentFileName
    , documentFileSize
    , documentFileUniqueId
    , documentMimeType
    , messageChat
    , messageDate
    , messageDocument
    , messageMessageId
    , messageSuccessfulPayment
    , messageText
    , pollAnswerOptionIds
    , pollAnswerPollId
    , preCheckoutQueryCurrency
    , preCheckoutQueryFrom
    , preCheckoutQueryId
    , preCheckoutQueryInvoicePayload
    , preCheckoutQueryTotalAmount
    , successfulPaymentCurrency
    , successfulPaymentInvoicePayload
    , successfulPaymentTelegramPaymentChargeId
    , successfulPaymentTotalAmount
    , updateMessage
    , userId
    )
import Telegram.Bot.API.GettingUpdates
    ( UpdateId (..)
    , updateCallbackQuery
    , updateChatId
    , updatePollAnswer
    , updatePreCheckoutQuery
    , updateUpdateId
    )
import Telegram.Bot.API.Types (FileId (..), MessageId (..), PollId (..))
import LazyCircus.Testing.Updates
    ( defaultTestChatId
    , defaultTestUserId
    , mkCallbackQueryUpdate
    , mkDocument
    , mkDocumentUpdate
    , mkFileUpdate
    , mkPollAnswerUpdate
    , mkPreCheckoutQueryUpdate
    , mkPreCheckoutQueryUpdateByUser
    , mkSuccessfulPaymentUpdate
    , mkSuccessfulPaymentUpdateByUser
    , mkTextUpdateByUser
    , newUpdateFactory
    , nextUpdateId
    )

spec :: Spec
spec = do
    describe "UpdateFactory generators" $ do
        it "mkTextUpdateByUser produces a valid text Update in the given chat" $ do
            factory <- newUpdateFactory
            u <- mkTextUpdateByUser factory (UserId 7) (ChatId 42) "hello"
            updateChatId u `shouldBe` Just (ChatId 42)
            (updateMessage u >>= messageText) `shouldBe` Just "hello"

        it "successive updates get strictly increasing update_id" $ do
            factory <- newUpdateFactory
            u1 <- mkTextUpdateByUser factory (UserId 1) (ChatId 1) "a"
            u2 <- mkTextUpdateByUser factory (UserId 1) (ChatId 1) "b"
            u3 <- mkTextUpdateByUser factory (UserId 1) (ChatId 1) "c"
            let ids = [updateUpdateId u1, updateUpdateId u2, updateUpdateId u3]
            ids `shouldBe` [UpdateId 1, UpdateId 2, UpdateId 3]
            ids `shouldSatisfy` strictlyIncreasing

            -- nextUpdateId independently returns 1, 2, 3 for a fresh factory
            fresh <- newUpdateFactory
            n1 <- nextUpdateId fresh
            n2 <- nextUpdateId fresh
            n3 <- nextUpdateId fresh
            [n1, n2, n3] `shouldBe` [1, 2, 3]

        it "mkCallbackQueryUpdate carries the target message id and callback data" $ do
            factory <- newUpdateFactory
            u <- mkCallbackQueryUpdate factory (UserId 1) (ChatId 5) (MessageId 99) "confirm"
            updateCallbackQuery u `shouldSatisfy` isJust
            let Just cq = updateCallbackQuery u
            callbackQueryData cq `shouldBe` Just "confirm"
            (messageMessageId <$> callbackQueryMessage cq) `shouldBe` Just (MessageId 99)

        it "mkDocumentUpdate carries the client-declared name, mime type, and size" $ do
            factory <- newUpdateFactory
            let doc =
                    (mkDocument (FileId "doc-9"))
                        { documentFileName = Just "report.pdf"
                        , documentMimeType = Just "application/pdf"
                        , documentFileSize = Just 12345
                        }
            u <- mkDocumentUpdate factory (UserId 7) (ChatId 42) doc
            updateChatId u `shouldBe` Just (ChatId 42)
            let Just msg = updateMessage u
                Just d = messageDocument msg
            documentFileId d `shouldBe` FileId "doc-9"
            documentFileUniqueId d `shouldBe` FileId "doc-9"
            documentFileName d `shouldBe` Just "report.pdf"
            documentMimeType d `shouldBe` Just "application/pdf"
            documentFileSize d `shouldBe` Just 12345

        it "mkFileUpdate produces a metadata-free document (unique id mirrors the file id)" $ do
            factory <- newUpdateFactory
            u <- mkFileUpdate factory (UserId 7) (ChatId 42) (FileId "doc-1")
            let Just msg = updateMessage u
                Just d = messageDocument msg
            documentFileId d `shouldBe` FileId "doc-1"
            documentFileUniqueId d `shouldBe` FileId "doc-1"
            documentFileName d `shouldBe` Nothing
            documentMimeType d `shouldBe` Nothing
            documentFileSize d `shouldBe` Nothing

        it "mkPollAnswerUpdate builds a chat-less update carrying the poll id and chosen options" $ do
            factory <- newUpdateFactory
            u <- mkPollAnswerUpdate factory (UserId 1001) (PollId "abc") [1, 3]
            updateChatId u `shouldBe` Nothing
            case updatePollAnswer u of
                Nothing -> expectationFailure "expected updatePollAnswer to be Just, got Nothing"
                Just pa -> do
                    pollAnswerPollId pa `shouldBe` PollId "abc"
                    pollAnswerOptionIds pa `shouldBe` [1, 3]

        it "mkPollAnswerUpdate round-trips a numeric-looking poll id as a string, not a number" $ do
            factory <- newUpdateFactory
            u <- mkPollAnswerUpdate factory (UserId 1001) (PollId "123") [0]
            updateChatId u `shouldBe` Nothing
            case updatePollAnswer u of
                Nothing -> expectationFailure "expected updatePollAnswer to be Just, got Nothing"
                Just pa -> pollAnswerPollId pa `shouldBe` PollId "123"

    describe "Telegram Stars (XTR) builders" $ do
        it "mkPreCheckoutQueryUpdate parses a chat-less pre_checkout_query with the given id, user, amount, and payload" $ do
            let u = mkPreCheckoutQueryUpdate "pcq-1" "pkg-buy" 250
            updateChatId u `shouldBe` Nothing
            case updatePreCheckoutQuery u of
                Nothing -> expectationFailure "expected updatePreCheckoutQuery to be Just, got Nothing"
                Just q -> do
                    preCheckoutQueryId q `shouldBe` "pcq-1"
                    userId (preCheckoutQueryFrom q) `shouldBe` defaultTestUserId
                    preCheckoutQueryCurrency q `shouldBe` "XTR"
                    preCheckoutQueryTotalAmount q `shouldBe` 250
                    preCheckoutQueryInvoicePayload q `shouldBe` "pkg-buy"

        it "mkSuccessfulPaymentUpdate parses the successful_payment service message with chat, date, and message id" $ do
            let u = mkSuccessfulPaymentUpdate "charge-9" "pkg-buy" 300
            let Just msg = updateMessage u
                Just payment = messageSuccessfulPayment msg
            successfulPaymentTelegramPaymentChargeId payment `shouldBe` "charge-9"
            successfulPaymentTotalAmount payment `shouldBe` 300
            successfulPaymentInvoicePayload payment `shouldBe` "pkg-buy"
            successfulPaymentCurrency payment `shouldBe` "XTR"
            -- the carrier message is a private-chat service message (update_id = 0, chat id 1)
            chatId (messageChat msg) `shouldBe` defaultTestChatId
            messageDate msg `shouldBe` 0
            messageMessageId msg `shouldBe` MessageId 0

        it "mkPreCheckoutQueryUpdateByUser builds a chat-less update from the given user" $ do
            factory <- newUpdateFactory
            u <- mkPreCheckoutQueryUpdateByUser factory (UserId 7) "pcq-2" "pkg-sub" 99
            updateChatId u `shouldBe` Nothing
            case updatePreCheckoutQuery u of
                Nothing -> expectationFailure "expected updatePreCheckoutQuery to be Just, got Nothing"
                Just q -> do
                    preCheckoutQueryId q `shouldBe` "pcq-2"
                    userId (preCheckoutQueryFrom q) `shouldBe` UserId 7
                    preCheckoutQueryCurrency q `shouldBe` "XTR"
                    preCheckoutQueryTotalAmount q `shouldBe` 99
                    preCheckoutQueryInvoicePayload q `shouldBe` "pkg-sub"

        it "mkSuccessfulPaymentUpdateByUser mirrors the fresh update_id into the carrier message id" $ do
            factory <- newUpdateFactory
            u <- mkSuccessfulPaymentUpdateByUser factory (UserId 7) (ChatId 42) "charge-2" "pkg-sub" 125
            updateChatId u `shouldBe` Just (ChatId 42)
            updateUpdateId u `shouldBe` UpdateId 1
            let Just msg = updateMessage u
                Just payment = messageSuccessfulPayment msg
            messageMessageId msg `shouldBe` MessageId 1
            successfulPaymentTelegramPaymentChargeId payment `shouldBe` "charge-2"
            successfulPaymentTotalAmount payment `shouldBe` 125
            successfulPaymentInvoicePayload payment `shouldBe` "pkg-sub"

        it "Stars builders draw strictly increasing update_id from one factory" $ do
            factory <- newUpdateFactory
            u1 <- mkPreCheckoutQueryUpdateByUser factory (UserId 1) "pcq-3" "pkg" 1
            u2 <- mkSuccessfulPaymentUpdateByUser factory (UserId 1) (ChatId 1) "charge-3" "pkg" 2
            [updateUpdateId u1, updateUpdateId u2] `shouldBe` [UpdateId 1, UpdateId 2]
            [updateUpdateId u1, updateUpdateId u2] `shouldSatisfy` strictlyIncreasing

-- | Predicate: consecutive elements are in strictly ascending order.
-- POST-CONTRACT: True for the empty and singleton lists.
strictlyIncreasing :: Ord a => [a] -> Bool
strictlyIncreasing xs = and (zipWith (<) xs (drop 1 xs))
