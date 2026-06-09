{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Unit tests for BotApp routing logic (handleUpdate).
-- Tests the pure update parser without needing a running bot or database.
module BotAppSpec (spec) where

import Data.Aeson (fromJSON, Value (Object), (.=), object)
import Data.Aeson.Types (Result (..))
import RIO hiding (ask)
import Data.Int (Int32)
import Test.Hspec

import BotApp (Action (..), ChatState (..), Model (..), handleUpdate)
import Telegram.Bot.API (Update (..))

-- | Build a minimal Update from JSON that carries a text message.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Returns a valid Update with the given text, or 'error' if JSON parse fails.
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

-- | Model in Idle state, used as the default for routing tests.
idleModel :: Model
idleModel = Model Idle

spec :: Spec
spec = do
    describe "handleUpdate" $ do
        it "routes /start to HandleStart" $ do
            handleUpdate idleModel (mkTextUpdate "/start")
                `shouldBe` Just HandleStart

        it "routes /newact to HandleNewAct" $ do
            handleUpdate idleModel (mkTextUpdate "/newact")
                `shouldBe` Just HandleNewAct

        it "routes /list to HandleList" $ do
            handleUpdate idleModel (mkTextUpdate "/list")
                `shouldBe` Just HandleList

        it "routes /act <id> to HandleViewAct" $ do
            handleUpdate idleModel (mkTextUpdate "/act 42")
                `shouldBe` Just (HandleViewAct 42)

        it "routes /react <id> to HandleReactAct" $ do
            handleUpdate idleModel (mkTextUpdate "/react 7")
                `shouldBe` Just (HandleReactAct 7)

        it "routes /delete <id> to HandleDeleteAct" $ do
            handleUpdate idleModel (mkTextUpdate "/delete 3")
                `shouldBe` Just (HandleDeleteAct 3)

        it "routes arbitrary text to HandleTextMessage" $ do
            handleUpdate idleModel (mkTextUpdate "Сколько будет 15 + 27?")
                `shouldBe` Just (HandleTextMessage "Сколько будет 15 + 27?")

        it "routes text without command to HandleTextMessage" $ do
            handleUpdate idleModel (mkTextUpdate "Hello, bot!")
                `shouldBe` Just (HandleTextMessage "Hello, bot!")
