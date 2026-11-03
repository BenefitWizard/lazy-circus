{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | The scenario-level 'sendImportantMessage' delivery policy: one attempt
now, a deferred retry parked through 'runAsyncAfter' when Telegram
rate-limits the send, and immediate rethrow of non-rate-limit rejections.

Drives the test performer's Telegram mocks with canned responses — a canned
@ok = False@ response is classified as a rejection exactly like production —
and executes the parked retry by firing the captured timer with
'fireScheduledTimers'.
-}
module ImportantMessageRetrySpec (spec) where

import Control.Exception qualified as E
import RIO hiding (try)
import Test.Hspec

import DemoEnv (DemoConfig (..), defaultDemoConfig, withDemoApp)
import LazyCircus (sendImportantMessage)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Telegram.Default qualified as TGDefault
import LazyCircus.Telegram.Types (TelegramApiRejected (..))
import LazyCircus.Testing.Performer
    ( Mocks (..)
    , createTgMock
    , defaultTestConfig
    , fireScheduledTimers
    , makeMocks
    , omText
    , readOutgoingMailbox
    , readScheduledTimers
    , readTgRequests
    , runScenarioProgram
    , runWithConfig
    , runWithMocks
    )
import SimpleServiceLib (AllServices)
import Telegram.Bot.API
    ( ChatId (..)
    , Message
    , Response (..)
    , ResponseParameters (..)
    , Seconds (..)
    , SendMessageRequest
    , SomeChatId (..)
    , defSendMessage
    )

-- | Demo configuration that registers one Telegram bot (@demo-bot@) so that
-- sends are captured by the test performer's mocks.
botTestConfig :: DemoConfig
botTestConfig = defaultDemoConfig{cfgTgToken = Just "123456:test-token"}

-- | Run an action with a 'DefaultApp' that has @demo-bot@ configured.
withBotTestApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withBotTestApp action = withDemoApp botTestConfig $ \app -> action app

-- | Canned 429 rejection with a server-advised @retry_after@ of 3 seconds.
rateLimitedResponse :: Response Message
rateLimitedResponse =
    (TGDefault.defaultResponse (Just 429) TGDefault.defaultMessage)
        { responseOk = False
        , responseDescription = Just "Too Many Requests: retry after 3"
        , responseParameters =
            Just
                ResponseParameters
                    { responseParametersMigrateToChatId = Nothing
                    , responseParametersRetryAfter = Just (Seconds 3)
                    }
        }

-- | Canned 400 rejection: not retryable, must surface to the caller.
badRequestResponse :: Response Message
badRequestResponse =
    (TGDefault.defaultResponse (Just 400) TGDefault.defaultMessage)
        { responseOk = False
        , responseDescription = Just "Bad Request: chat not found"
        }

-- | The important message under delivery.
importantRequest :: SendMessageRequest
importantRequest = defSendMessage (SomeChatId (ChatId 42)) "important"

-- | Build fresh mocks whose Telegram mock serves the supplied canned
-- responses FIFO before falling back to the standard ok response.
mocksWithResponses :: [Response Message] -> IO (Mocks AllServices)
mocksWithResponses responses = do
    base <- makeMocks
    tgM <- createTgMock (TGDefault.defaultResponse Nothing TGDefault.defaultMessage) (Just (map const responses)) []
    pure base{tgMock = tgM}

-- | Run the important-send delivery policy once through the test interpreter.
runImportantSend :: DefaultApp AllServices -> Mocks AllServices -> IO ()
runImportantSend app mocks =
    runWithMocks app mocks $
        runScenarioProgram (sendImportantMessage "demo-bot" importantRequest)

spec :: Spec
spec = aroundAll withBotTestApp $ do
    describe "sendImportantMessage (rate-limited deferred retry)" $ do
        it "parks a deferred retry on 429 and delivers on the second attempt" $ \app -> do
            mocks <- mocksWithResponses [rateLimitedResponse]
            runImportantSend app mocks

            -- First attempt was rejected: the request is captured, a retry
            -- timer is parked for retry_after + margin (3 + 1), nothing is
            -- delivered and the scenario returned without blocking.
            tgReqs <- readTgRequests mocks
            length tgReqs `shouldBe` 1
            timers <- readScheduledTimers mocks
            map fst timers `shouldBe` [4]
            outgoing <- readOutgoingMailbox mocks
            length outgoing `shouldBe` 0

            -- Fire the parked retry: the second attempt dequeues the ok
            -- fallback response and delivers the message.
            runWithConfig app defaultTestConfig mocks fireScheduledTimers
            outgoingAfter <- readOutgoingMailbox mocks
            map omText outgoingAfter `shouldBe` [Just "important"]
            tgReqsAfter <- readTgRequests mocks
            length tgReqsAfter `shouldBe` 2
            -- Delivery succeeded: no further retry is parked.
            timersAfter <- readScheduledTimers mocks
            length timersAfter `shouldBe` 0

        it "keeps parking retries while the rate limit persists" $ \app -> do
            mocks <- mocksWithResponses [rateLimitedResponse, rateLimitedResponse]
            runImportantSend app mocks
            runWithConfig app defaultTestConfig mocks fireScheduledTimers
            -- Both attempts were rate-limited: two captured attempts, another
            -- retry parked, still nothing delivered.
            tgReqs <- readTgRequests mocks
            length tgReqs `shouldBe` 2
            timers <- readScheduledTimers mocks
            map fst timers `shouldBe` [4]
            outgoing <- readOutgoingMailbox mocks
            length outgoing `shouldBe` 0

        it "rethrows non-rate-limit rejections without parking a retry" $ \app -> do
            mocks <- mocksWithResponses [badRequestResponse]
            outcome <- E.try (runImportantSend app mocks)
            case outcome of
                Left (rej :: TelegramApiRejected) -> do
                    telegramApiRejectedErrorCode rej `shouldBe` Just 400
                    telegramApiRejectedDescription rej `shouldBe` Just "Bad Request: chat not found"
                Right () -> expectationFailure "expected the non-rate-limit rejection to propagate"
            timers <- readScheduledTimers mocks
            length timers `shouldBe` 0
            outgoing <- readOutgoingMailbox mocks
            length outgoing `shouldBe` 0
