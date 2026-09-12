{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the 'Tg.sendPoll' effect and its mock in the test performer.
--
-- Sending a poll via @tgScript "demo-bot" ('Tg.sendPoll' req)@ under
-- 'runWithDefaultMocks' must capture exactly one 'OutSendPoll' in the outgoing
-- mailbox (question text, chat id), return a @('PollId', 'Message')@ pair
-- consistent with the mock's incremental id stamping (with the poll stamped
-- into the message), and — with journaling enabled via @tcJournal@ — record
-- an 'ObsTgPoll' observation carrying the same chat id and question.
--
-- The final example pins the facade re-export: 'Facade.sendPoll' imported
-- from "LazyCircus.Scene.Telegram" must be the effect's smart constructor
-- wired to the performer, not merely a compilable name.
module SendPollSpec (spec) where

import RIO
import Test.Hspec

import LazyCircus (Script, tgScript)
import LazyCircus.Scenario (evalScript)
import LazyCircus.Scene.Telegram qualified as Facade (sendPoll)
import LazyCircus.Scene.Telegram.Lang qualified as Tg (sendPoll)
import LazyCircus.Testing.Bdd.Journal
    ( Observation (..)
    , ObservationLog
    , newObservationLog
    , readObservations
    )
import LazyCircus.Testing.Performer
    ( OutgoingKind (..)
    , OutgoingMessage (..)
    , TestConfig (..)
    , defaultTestConfig
    , readOutgoingMailbox
    , runScenarioProgram
    , runWithDefaultConfig
    , runWithDefaultMocks
    )
import Telegram.Bot.API
    ( ChatId (..)
    , InputPollOption (..)
    , Message
    , SendPollRequest
    , SomeChatId (..)
    , defSendPoll
    , messageMessageId
    , messagePoll
    , pollId
    , sendPollIsAnonymous
    )
import Telegram.Bot.API.Types (MessageId (..), PollId (..))
import TestHelpers.Bot (withBotTestApp)

-- | Target chat id used by every example in this spec.
demoChatId :: ChatId
demoChatId = ChatId 42

-- | Question text of the poll sent by the shared scenario.
demoQuestion :: Text
demoQuestion = "Which circus act do you like most?"

-- | Answer options of the poll sent by the shared scenario.
-- Each option is built positionally: @text@, @parseMode@ ('Nothing' = plain),
-- @entities@ ('Nothing').
demoPollOptions :: [InputPollOption]
demoPollOptions =
    [ InputPollOption "Jugglers" Nothing Nothing
    , InputPollOption "Acrobats" Nothing Nothing
    ]

-- | A representative @sendPoll@ request: two plain-text options in the demo
-- chat, non-anonymous (mirroring the demo bot's @\/poll@ command).
-- POST-CONTRACT: Built with 'defSendPoll' (this pin has no @defSendPollRequest@).
demoReq :: SendPollRequest
demoReq =
    (defSendPoll (SomeChatId demoChatId) demoQuestion demoPollOptions)
        { sendPollIsAnonymous = Just False
        }

-- | The shared scenario: send one poll as @demo-bot@ and return the
-- @('PollId', 'Message')@ pair the mock produces.
sendPollScenario :: Script (PollId, Message)
sendPollScenario = tgScript "demo-bot" $ Tg.sendPoll demoReq

-- | The facade scenario: identical to 'sendPollScenario' but invokes
-- 'Facade.sendPoll' re-exported from "LazyCircus.Scene.Telegram" instead of
-- the defining module — pinning that the facade symbol is the effect's smart
-- constructor wired to the performer.
facadeSendPollScenario :: Script (PollId, Message)
facadeSendPollScenario = tgScript "demo-bot" $ Facade.sendPoll demoReq

-- | Question text of the second poll, distinct from 'demoQuestion' so the two
-- captures are distinguishable by content.
demoQuestionFollowUp :: Text
demoQuestionFollowUp = "Which act should open the show?"

-- | A second representative @sendPoll@ request: same chat and options as
-- 'demoReq', different question.
-- POST-CONTRACT: Built with 'defSendPoll' (this pin has no @defSendPollRequest@).
demoReqFollowUp :: SendPollRequest
demoReqFollowUp =
    (defSendPoll (SomeChatId demoChatId) demoQuestionFollowUp demoPollOptions)
        { sendPollIsAnonymous = Just False
        }

-- | The two-poll scenario: two 'Tg.sendPoll' calls inside ONE @tgScript@,
-- returning both @('PollId', 'Message')@ pairs.
sendTwoPollsScenario :: Script ((PollId, Message), (PollId, Message))
sendTwoPollsScenario = tgScript "demo-bot" $ do
    firstResult <- Tg.sendPoll demoReq
    secondResult <- Tg.sendPoll demoReqFollowUp
    pure (firstResult, secondResult)

spec :: Spec
spec = aroundAll withBotTestApp $
    describe "SendPoll" $ do
        it "captures exactly one OutSendPoll with the question and chat id" $ \app -> do
            (mocks, _) <- runWithDefaultMocks app $
                runScenarioProgram (evalScript sendPollScenario)
            captures <- readOutgoingMailbox mocks
            map omKind captures `shouldBe` [OutSendPoll]
            map omText captures `shouldBe` [Just demoQuestion]
            map omChatId captures `shouldBe` [Just demoChatId]

        it "returns a PollId/Message pair consistent with the capture's assigned id" $ \app -> do
            (mocks, (returnedPollId, msg)) <- runWithDefaultMocks app $
                runScenarioProgram (evalScript sendPollScenario)
            captures <- readOutgoingMailbox mocks
            case captures of
                [OutgoingMessage{omMessageId = Just mid}] -> do
                    mid `shouldBe` MessageId 0
                    returnedPollId `shouldBe` PollId ("poll-" <> tshow mid)
                    messageMessageId msg `shouldBe` mid
                    case messagePoll msg of
                        Just stampedPoll -> pollId stampedPoll `shouldBe` returnedPollId
                        Nothing ->
                            expectationFailure
                                "Expected messagePoll to be Just, got Nothing: mock did not stamp the poll into the returned message"
                _ ->
                    expectationFailure $
                        "Expected exactly one OutSendPoll capture with an assigned id, got: " <> show captures

        it "journals ObsTgPoll with the chat id and question when tcJournal is set" $ \app -> do
            journal <- newObservationLog :: IO (ObservationLog ())
            let cfg = defaultTestConfig{tcJournal = Just journal}
            (mocks, _) <-
                runWithDefaultConfig app cfg $
                    runScenarioProgram (evalScript sendPollScenario)
            observed <- readObservations journal
            observed
                `shouldBe` [ObsTgPoll{obsChatId = Just demoChatId, obsQuestion = demoQuestion}]
            captures <- readOutgoingMailbox mocks
            length captures `shouldBe` 1

        it "assigns distinct PollIds and MessageIds to two sends in one script" $ \app -> do
            (mocks, ((firstPollId, firstMsg), (secondPollId, secondMsg))) <- runWithDefaultMocks app $
                runScenarioProgram (evalScript sendTwoPollsScenario)
            -- Single destructive drain AFTER both sends: the mailbox still
            -- holds both captures (nothing drained them mid-scenario).
            captures <- readOutgoingMailbox mocks
            map omKind captures `shouldBe` [OutSendPoll, OutSendPoll]
            map omText captures `shouldBe` [Just demoQuestion, Just demoQuestionFollowUp]
            map omMessageId captures `shouldBe` [Just (MessageId 0), Just (MessageId 1)]
            messageMessageId firstMsg `shouldBe` MessageId 0
            messageMessageId secondMsg `shouldBe` MessageId 1
            firstPollId `shouldNotBe` secondPollId
            messageMessageId firstMsg `shouldNotBe` messageMessageId secondMsg
            firstPollId `shouldBe` PollId ("poll-" <> tshow (messageMessageId firstMsg))
            secondPollId `shouldBe` PollId ("poll-" <> tshow (messageMessageId secondMsg))

        it "sendPoll imported from the LazyCircus.Scene.Telegram facade captures exactly one OutSendPoll" $ \app -> do
            (mocks, _) <- runWithDefaultMocks app $
                runScenarioProgram (evalScript facadeSendPollScenario)
            -- Single destructive drain: the mailbox holds the one facade-driven
            -- capture and nothing else.
            captures <- readOutgoingMailbox mocks
            map omKind captures `shouldBe` [OutSendPoll]
            map omText captures `shouldBe` [Just demoQuestion]
            map omChatId captures `shouldBe` [Just demoChatId]
