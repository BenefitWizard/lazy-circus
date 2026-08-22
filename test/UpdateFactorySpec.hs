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
    , documentFileId
    , documentFileName
    , documentFileSize
    , documentFileUniqueId
    , documentMimeType
    , messageDocument
    , messageMessageId
    , messageText
    , updateMessage
    )
import Telegram.Bot.API.GettingUpdates
    ( UpdateId (..)
    , updateCallbackQuery
    , updateChatId
    , updateUpdateId
    )
import Telegram.Bot.API.Types (FileId (..), MessageId (..))
import LazyCircus.Testing.Updates
    ( mkCallbackQueryUpdate
    , mkDocument
    , mkDocumentUpdate
    , mkFileUpdate
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

-- | Predicate: consecutive elements are in strictly ascending order.
-- POST-CONTRACT: True for the empty and singleton lists.
strictlyIncreasing :: Ord a => [a] -> Bool
strictlyIncreasing xs = and (zipWith (<) xs (drop 1 xs))
