{-# LANGUAGE OverloadedStrings #-}

{- | The 'sendLongMessage' composite: chunked delivery of oversized
'SendMessageRequest' texts under the test performer's Telegram mocks.

Mirrors 'TgMockMailboxSpec' setup: a 'DefaultApp' with one Telegram bot
(@demo-bot@) registered, driven through 'runScenarioProgram' under the test
performer, with sends captured via 'readTgRequests'.
-}
module SendLongMessageSpec (spec) where

import RIO
import Test.Hspec

import Data.Text qualified as T

import DemoEnv (DemoConfig (..), defaultDemoConfig, withDemoApp)
import LazyCircus (tgScript)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Scenario (ScenarioProgram, evalScript)
import LazyCircus.Scene.Telegram.Lang qualified as Tg (sendLongMessage)
import LazyCircus.Script (Script)
import LazyCircus.Telegram.LongText (splitTelegramText, telegramMessageChunkLimit)
import LazyCircus.Telegram.Types (WithImportance (..))
import LazyCircus.Testing.Performer (readTgRequests, runScenarioProgram, runWithDefaultMocks)
import SimpleServiceLib (AllServices)
import Telegram.Bot.API
    ( ChatId (..)
    , Message
    , Response (..)
    , SendMessageRequest
    , SomeChatId (..)
    , defSendMessage
    , sendMessageChatId
    , sendMessageParseMode
    , sendMessageText
    )
import Telegram.Bot.API.Types.ParseMode (ParseMode (..))

-- | Demo configuration that registers one Telegram bot (@demo-bot@) so that
-- 'sendLongMessage' sends are captured by the test performer's mocks.
botTestConfig :: DemoConfig
botTestConfig = defaultDemoConfig{cfgTgToken = Just "123456:test-token"}

-- | Run an action with a 'DefaultApp' that has @demo-bot@ configured.
withBotTestApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withBotTestApp action = withDemoApp botTestConfig $ \app -> action app

-- | Unwrap the 'SendMessageRequest' carried by a 'WithImportance' marker.
importancePayload :: WithImportance SendMessageRequest -> SendMessageRequest
importancePayload (Regular req) = req
importancePayload (Important req) = req

-- | Run 'Tg.sendLongMessage' as @demo-bot@ through the scene script language.
sendLongScenario :: SendMessageRequest -> ScenarioProgram Script serviceLib [Response Message]
sendLongScenario request =
    evalScript $ tgScript "demo-bot" $ Tg.sendLongMessage request

spec :: Spec
spec = aroundAll withBotTestApp $ do
    describe "SendLongMessage" $ do
        it "sends one request per chunk, preserving parse mode and chat id" $ \app -> do
            let longText = T.replicate 9000 "x" -- no natural boundaries: hard cuts
                request =
                    (defSendMessage (SomeChatId (ChatId 42)) longText)
                        { sendMessageParseMode = Just HTML
                        }

            (mocks, responses) <-
                runWithDefaultMocks app $
                    runScenarioProgram $ sendLongScenario request

            requests <- map importancePayload <$> readTgRequests mocks
            let expectedChunks = splitTelegramText longText
            T.length longText `shouldSatisfy` (> telegramMessageChunkLimit)
            map sendMessageText requests `shouldBe` expectedChunks
            length requests `shouldBe` 3
            case map sendMessageParseMode requests of
                [Just HTML, Just HTML, Just HTML] -> pure ()
                modes -> fail ("parse_mode not preserved across chunks: " <> show (length modes) <> " requests")
            case map sendMessageChatId requests of
                [SomeChatId (ChatId 42), SomeChatId (ChatId 42), SomeChatId (ChatId 42)] -> pure ()
                _ -> fail "chat id not preserved across chunks"
            map responseOk responses `shouldBe` [True, True, True]

        it "sends a short text as exactly one message" $ \app -> do
            let request =
                    (defSendMessage (SomeChatId (ChatId 7)) "short")
                        { sendMessageParseMode = Just HTML
                        }

            (mocks, responses) <-
                runWithDefaultMocks app $
                    runScenarioProgram $ sendLongScenario request

            requests <- map importancePayload <$> readTgRequests mocks
            map sendMessageText requests `shouldBe` ["short"]
            case map sendMessageParseMode requests of
                [Just HTML] -> pure ()
                modes -> fail ("parse_mode not preserved: " <> show (length modes) <> " requests")
            case map sendMessageChatId requests of
                [SomeChatId (ChatId 7)] -> pure ()
                _ -> fail "chat id not preserved"
            map responseOk responses `shouldBe` [True]
