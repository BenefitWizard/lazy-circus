{-# LANGUAGE OverloadedStrings #-}

-- | Pure pins for the three-way classification behind the production
-- @sendPoll@ wrapper ('LazyCircus.Telegram.classifyPollResponse').
--
-- These examples pin the dispatch order — an API rejection (@ok=false@) is
-- detected BEFORE poll extraction, so a rejection wins even when the payload
-- carries a poll — plus the two @ok=true@ outcomes: poll extracted as a
-- @('PollId', 'Message')@ pair, and the poll-less payload preserved verbatim.
module ClassifyPollResponseSpec (spec) where

import Test.Hspec

import LazyCircus.Telegram (PollResponse (..), classifyPollResponse)
import LazyCircus.Telegram.Default (defaultMessage, defaultPoll, defaultResponse)
import LazyCircus.Telegram.Types (TelegramApiRejected (..))
import Telegram.Bot.API
    ( messageMessageId
    , messagePoll
    , messageText
    , pollId
    , responseDescription
    , responseOk
    , responseResult
    )
import Telegram.Bot.API.Types (PollId (..))

-- 'Response' has no 'Eq' instance, so each example pins its branch by pattern
-- matching and field-level assertions; any other branch fails via 'show'.
spec :: Spec
spec =
    describe "classifyPollResponse" $ do
        it "classifies ok=false as PollRejected, preserving code and description" $ do
            let rejectedResp =
                    (defaultResponse (Just 400) defaultMessage)
                        { responseOk = False
                        , responseDescription = Just "Bad Request: question text is empty"
                        }
            case classifyPollResponse rejectedResp of
                PollRejected rejection -> do
                    telegramApiRejectedErrorCode rejection `shouldBe` Just 400
                    telegramApiRejectedDescription rejection `shouldBe` Just "Bad Request: question text is empty"
                other -> expectationFailure ("expected PollRejected, got: " <> show other)

        it "checks the API rejection BEFORE poll extraction (rejection wins even when a poll is present)" $ do
            let contradictoryResp =
                    (defaultResponse (Just 403) defaultMessage{messagePoll = Just defaultPoll{pollId = PollId "poll-order"}})
                        { responseOk = False
                        , responseDescription = Just "rejected"
                        }
            case classifyPollResponse contradictoryResp of
                PollRejected _ -> pure ()
                other ->
                    expectationFailure $
                        "rejection guard must fire before poll extraction, got: " <> show other

        it "classifies ok=true with a poll as PollExtracted carrying the poll id and message" $ do
            let msg = defaultMessage{messagePoll = Just defaultPoll{pollId = PollId "poll-1"}}
                okResp = defaultResponse Nothing msg
            case classifyPollResponse okResp of
                PollExtracted (returnedPollId, returnedMsg) -> do
                    returnedPollId `shouldBe` PollId "poll-1"
                    messageMessageId returnedMsg `shouldBe` messageMessageId msg
                other -> expectationFailure ("expected PollExtracted, got: " <> show other)

        it "classifies ok=true without a poll as PollMissing preserving the poll-less payload" $ do
            let pollless = defaultMessage
                okResp = defaultResponse Nothing pollless
            case classifyPollResponse okResp of
                PollMissing preserved -> do
                    responseOk preserved `shouldBe` True
                    messageText (responseResult preserved) `shouldBe` messageText pollless
                other -> expectationFailure ("expected PollMissing, got: " <> show other)
