{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- | Tests for the configurable 'TestPerformer' — per-sub-language Mocked vs
Real mode selection via 'TestConfig'.

Verifies the branching contract of 'LazyCircus.Testing.Performer':

* In 'Mocked' mode, side effects are captured in the mock refs
  ('readAiRequests', 'readSentMails', 'readOutgoingMailbox', 'readTgRequests').
* In 'Real' mode, the performer delegates to production implementations and
  does NOT capture side effects — proven here by asserting the capture refs
  are empty after a (necessarily failing) real call. Real branches hit
  external services (no live AI/SMTP/token), so each Real test wraps the run
  in @try \@SomeException@ and then asserts the capture buffer is empty,
  which is sufficient evidence of Real-branch routing.
* 'LazyCircus.Testing.TgTest.tgTest' refuses to start when
  'tcTelegram' = 'Real', throwing 'TgTestConfigError' before the headless
  bot is spawned.
-}
module ConfigurablePerformerSpec (spec) where

import Control.Exception qualified as E
import Data.Aeson (Value)
import DemoEnv (DemoConfig (..), defaultDemoConfig, withDemoApp)
import LazyCircus (mailScript, tgScript)
import LazyCircus.AI (AIRequest (..))
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Scene.AI qualified as Scene (ask)
import LazyCircus.Scene.Mail.Lang qualified as Mail (makeMail, sendMail)
import LazyCircus.Scene.Telegram.Lang qualified as Tg (sendMessage)
import LazyCircus.Scenario (ScenarioProgram, evalScript)
import LazyCircus.Script (Script (..))
import LazyCircus.Testing.Performer
    ( Mode (..)
    , TestConfig (..)
    , defaultTestConfig
    , makeMocks
    , readAiRequests
    , readOutgoingMailbox
    , readSentMails
    , readTgRequests
    , runScenarioProgram
    , runWithConfig
    , runWithDefaultConfig
    )
import LazyCircus.Testing.TgTest
    ( TgTestConfig (..)
    , TgTestConfigError
    , defaultTgTestConfig
    , tgTest
    )
import Network.Mail.Mime (Address (..))
import RIO
import SimpleServiceLib (AllServices)
import Test.Hspec
import Telegram.Bot.API (ChatId (..), SomeChatId (..), defSendMessage)

-- | Demo configuration that registers one Telegram bot (@demo-bot@) so the
-- test performer's Real-Telegram branch has a bot environment to dispatch
-- against (mirrors 'TgMockMailboxSpec.botTestConfig').
botTestConfig :: DemoConfig
botTestConfig = defaultDemoConfig{cfgTgToken = Just "123456:test-token"}

-- | Run an action with a 'DefaultApp' that has @demo-bot@ configured.
withBotTestApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withBotTestApp action = withDemoApp botTestConfig $ \app -> action app

-- | A representative one-shot AI @ask@ request (no tools, no thinking).
calcAiReq :: AIRequest Value
calcAiReq =
    AIRequest
        { prompt = ["Calculate 2+2"]
        , systemPrompt = ["You are a calculator."]
        , outputType = Proxy
        , thinkingEnabled = False
        }

-- | A one-shot AI @ask@ script (no tools) reused across Mocked/Real scenarios.
askScript :: Script (Maybe Value)
askScript = AIScriptDef [] (Scene.ask calcAiReq)

-- | A mail script that constructs and sends one email.
mailSendScript :: Script ()
mailSendScript = mailScript $ do
    mail <- Mail.makeMail recipient "Test subject" "Test body"
    Mail.sendMail mail
  where
    -- \| Minimal recipient address (display name omitted).
    recipient = Address Nothing "recipient@example.com"

-- | Send one @sendMessage@ as @demo-bot@ to chat 1, discarding the response.
tgSendScenario :: ScenarioProgram Script serviceLib ()
tgSendScenario =
    void $
        evalScript $
            tgScript "demo-bot" $
                Tg.sendMessage (defSendMessage (SomeChatId (ChatId 1)) "hello")

spec :: Spec
spec = do
    aroundAll withBotTestApp $ do
        describe "Mocked capture (happy path)" $ do
            it "AI Mocked captures requests in readAiRequests" $ \app -> do
                (mocks, _) <-
                    runWithDefaultConfig app defaultTestConfig $
                        runScenarioProgram (evalScript askScript)
                captured <- readAiRequests mocks
                length captured `shouldBe` 1

            it "Mail Mocked captures sends in readSentMails" $ \app -> do
                (mocks, _) <-
                    runWithDefaultConfig app defaultTestConfig $
                        runScenarioProgram (evalScript mailSendScript)
                sent <- readSentMails mocks
                length sent `shouldBe` 1

            it "Telegram Mocked fills the outgoing mailbox" $ \app -> do
                (mocks, _) <-
                    runWithDefaultConfig app defaultTestConfig $
                        runScenarioProgram tgSendScenario
                outgoing <- readOutgoingMailbox mocks
                length outgoing `shouldBe` 1
                tgReqs <- readTgRequests mocks
                length tgReqs `shouldBe` 1

        describe "Real non-capture (exception + empty capture)" $ do
            it "AI Real does not capture requests (readAiRequests is empty)" $ \app -> do
                let cfg = defaultTestConfig{tcAI = Real}
                testMocks <- makeMocks
                _ <- E.try @E.SomeException $
                    runWithConfig app cfg testMocks $
                        runScenarioProgram (evalScript askScript)
                captured <- readAiRequests testMocks
                length captured `shouldBe` 0

            it "Mail Real does not capture sends (readSentMails is empty)" $ \app -> do
                let cfg = defaultTestConfig{tcMailSend = Real}
                testMocks <- makeMocks
                _ <- E.try @E.SomeException $
                    runWithConfig app cfg testMocks $
                        runScenarioProgram (evalScript mailSendScript)
                sent <- readSentMails testMocks
                length sent `shouldBe` 0

            it "Telegram Real does not fill the mailbox (readOutgoingMailbox is empty)" $ \app -> do
                let cfg = defaultTestConfig{tcTelegram = Real}
                testMocks <- makeMocks
                _ <- E.try @E.SomeException $
                    runWithConfig app cfg testMocks $
                        runScenarioProgram tgSendScenario
                outgoing <- readOutgoingMailbox testMocks
                length outgoing `shouldBe` 0
                tgReqs <- readTgRequests testMocks
                length tgReqs `shouldBe` 0

    describe "tgTest runtime guard" $ do
        it "throws TgTestConfigError when tcTelegram is Real" $ do
            let cfg =
                    defaultTgTestConfig
                        { ttgPerformerConfig = defaultTestConfig{tcTelegram = Real}
                        }
            result <-
                E.try @TgTestConfigError $
                    tgTest cfg (\_ _ -> pure (\_ -> pure ())) (pure ())
            case result of
                Left _ -> pure ()
                Right _ ->
                    expectationFailure
                        "Expected tgTest to throw TgTestConfigError before starting the headless bot"
