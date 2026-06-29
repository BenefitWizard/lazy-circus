{-# LANGUAGE OverloadedStrings #-}

{- | T7 completion spec: the 'LazyCircus.Testing.Performer' outgoing-mailbox
capture and the incremental 'MessageId' stamping that backs the @tgTest@ DSL's
@waitFor*@ correlation.

Mirrors the pilot 'TgTestSpec' setup: a 'DefaultApp' with one Telegram bot
(@demo-bot@) registered, driven through 'runScenarioProgram' under the test
performer so every 'sendMessage' is captured both in the legacy 'SomeRef' log
('readTgRequests') and in the new STM 'outgoingMailbox' ('readOutgoingMailbox').
-}
module TgMockMailboxSpec (spec) where

import RIO
import Test.Hspec

import DemoEnv (DemoConfig (..), defaultDemoConfig, withDemoApp)
import LazyCircus (tgScript)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Scenario (ScenarioProgram, evalScript)
import LazyCircus.Scene.Telegram.Lang qualified as Tg (sendMessage)
import LazyCircus.Script (Script)
import LazyCircus.Testing.Performer
    ( OutgoingKind (..)
    , OutgoingMessage (..)
    , readOutgoingMailbox
    , readTgRequests
    , runScenarioProgram
    , runWithDefaultMocks
    )
import SimpleServiceLib (AllServices)
import Telegram.Bot.API (ChatId (..), SomeChatId (..), defSendMessage)
import Telegram.Bot.API.Types (MessageId (..))

-- | Demo configuration that registers one Telegram bot (@demo-bot@) so that
-- 'sendMessage' replies are captured by the test performer's mailbox.
botTestConfig :: DemoConfig
botTestConfig = defaultDemoConfig{cfgTgToken = Just "123456:test-token"}

-- | Run an action with a 'DefaultApp' that has @demo-bot@ configured.
withBotTestApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withBotTestApp action = withDemoApp botTestConfig $ \app -> action app

-- | Send a @sendMessage@ reply as @demo-bot@ to the given chat, discarding the response.
sendTo :: ChatId -> Text -> ScenarioProgram Script serviceLib ()
sendTo chatId txt =
    void $
        evalScript $
            tgScript "demo-bot" $
                Tg.sendMessage (defSendMessage (SomeChatId chatId) txt)

spec :: Spec
spec = aroundAll withBotTestApp $ do
    describe "TgMock outgoing mailbox" $ do
        it "publishes two sends to the mailbox with distinct incremental message ids" $ \app -> do
            (mocks, _) <-
                runWithDefaultMocks app $
                    runScenarioProgram $ do
                        sendTo (ChatId 1) "first"
                        sendTo (ChatId 1) "second"

            msgs <- readOutgoingMailbox mocks
            length msgs `shouldBe` 2
            let [m1, m2] = msgs
            omKind m1 `shouldBe` OutSendMessage
            omKind m2 `shouldBe` OutSendMessage
            omText m1 `shouldBe` Just "first"
            omText m2 `shouldBe` Just "second"
            omChatId m1 `shouldBe` Just (ChatId 1)
            omChatId m2 `shouldBe` Just (ChatId 1)
            -- both message ids are present, distinct, and strictly increasing
            [ mid | Just mid <- map omMessageId msgs ] `shouldBe` [MessageId 0, MessageId 1]

            -- back-compat: the legacy SomeRef log is unchanged by the mailbox
            tgReqs <- readTgRequests mocks
            length tgReqs `shouldBe` 2

        it "message ids are strictly increasing across sends" $ \app -> do
            (mocks, _) <-
                runWithDefaultMocks app $
                    runScenarioProgram $ do
                        sendTo (ChatId 1) "a"
                        sendTo (ChatId 1) "b"
                        sendTo (ChatId 1) "c"

            msgs <- readOutgoingMailbox mocks
            length msgs `shouldBe` 3
            map omKind msgs `shouldBe` [OutSendMessage, OutSendMessage, OutSendMessage]
            [ mid | Just mid <- map omMessageId msgs ] `shouldBe` [MessageId 0, MessageId 1, MessageId 2]
