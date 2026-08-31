{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Unit tests for the observation journal
('LazyCircus.Testing.Bdd.Journal') wired through the test performer's
@TestConfig@ (@tcJournal@).

Drives small scenarios through the standard mock runner
('LazyCircus.Testing.Performer.runWithDefaultConfig' / 'runWithConfig') with a
journal configured, and asserts that the snapshot contains the expected
@ObsTg*@ sequence in commit order with incremental 'MessageId's consistent
with the outgoing mailbox contents, plus coverage of the @runAsync@ capture
and the mail\/AI app hooks.
-}
module Bdd.JournalSpec (spec) where

import RIO
import RIO.Set qualified as Set
import RIO.Vector qualified as V
import Test.Hspec

import Data.Aeson (Value)
import Data.Pool (destroyAllResources)
import LazyCircus (mailScript, tgScript)
import LazyCircus.AI (AIRequest, mkAIRequest)
import LazyCircus.App.Default
    ( DefaultApp (pgDbPool)
    , DefaultAppConfig (..)
    , MailCreds (..)
    , newDefaultApp
    )
import LazyCircus.App.Service (NoServiceLib (..))
import LazyCircus.Scenario (ScenarioProgram, evalScript, runAsync)
import LazyCircus.Scene.AI qualified as Scene (ask)
import LazyCircus.Scene.Mail.Lang qualified as Mail (sendMail)
import LazyCircus.Scene.Telegram.Lang qualified as Tg
    ( deleteMessage
    , editMessageText
    , sendMessage
    , setMessageReaction
    )
import LazyCircus.Script (Script (..))
import LazyCircus.Testing.Bdd.Journal
    ( AwaitTimeout (..)
    , DialogState (..)
    , Observation (..)
    , ObservationLog
    , ScenarioState (..)
    , Sequenced (..)
    , appendObservation
    , awaitObservation
    , defaultAwaitBudgetUs
    , newObservationLog
    , newScenarioState
    , peekLastConsumed
    , readObservations
    , ssLastConsumed
    )
import LazyCircus.Testing.Performer
    ( OutgoingMessage (..)
    , TestConfig (..)
    , defaultTestConfig
    , makeMocksWithAi
    , readOutgoingMailbox
    , runScenarioProgram
    , runWithConfig
    , runWithDefaultConfig
    )
import Network.Mail.Mime (Address (..), emptyMail)
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.Usage (Usage (..))
import Telegram.Bot.API
    ( ChatId (..)
    , SomeChatId (..)
    , defEditMessageText
    , defSendMessage
    , defSetMessageReaction
    , editMessageTextChatId
    , editMessageTextMessageId
    , editMessageTextText
    )
import Telegram.Bot.API.Types (MessageId (..))

-- | PostgreSQL connection string for the journal app fixture. Points at the
-- PostgreSQL maintenance database (which always exists), because the journal
-- scenarios below never touch the database — 'newDefaultApp' merely probes the
-- pool at construction.
fixtureConnectionString :: ByteString
fixtureConnectionString = "host=127.0.0.1 port=5432 user=postgres password=my_password dbname=postgres"

{- | Run an action with a minimal 'DefaultApp' that has one Telegram bot
(@demo-bot@) registered, so @tgScript "demo-bot"@ effects are captured by the
test performer.
PRE-CONTRACT: PostgreSQL must be reachable at 127.0.0.1:5432.
POST-CONTRACT: The read-write pool is destroyed after the action completes.
-}
withJournalApp :: (DefaultApp NoServiceLib -> IO ()) -> IO ()
withJournalApp action = do
    app <-
        newDefaultApp
            DefaultAppConfig
                { cfgPgConnectionString = fixtureConnectionString
                , cfgPgConnectionStringReadOnly = Nothing
                , cfgPgPoolMaxResources = 1
                , cfgBotConfigs = [("demo-bot", "123456:test-token")]
                , cfgAiApiKey = Nothing
                , cfgAiBaseUrl = Nothing
                , cfgMailCreds = MailCreds "127.0.0.1" 1025 "" "" "" False
                , cfgExtraContext = mempty
                , cfgSqlLogAction = Just (\_ -> pure ())
                , cfgServiceLib = NoServiceLib
                }
    action app `finally` destroyAllResources (pgDbPool app)

-- | Send a @sendMessage@ reply as @demo-bot@ to the given chat, discarding the response.
sendTo :: ChatId -> Text -> ScenarioProgram Script NoServiceLib ()
sendTo chatId txt =
    void $
        evalScript $
            tgScript "demo-bot" $
                Tg.sendMessage (defSendMessage (SomeChatId chatId) txt)

-- | A representative one-shot AI request (mirrors test/AiMockSpec.hs).
calcAiReq :: AIRequest Value
calcAiReq = mkAIRequest ["Calculate 2+2"] ["You are a calculator."]

-- | A simple @ask@ script used by the AI-hook test.
askScript :: Script (Maybe Value)
askScript = AIScriptDef [] (Scene.ask calcAiReq)

-- | Build a 'Chat.ChatCompletionObject' with a single Assistant choice
-- carrying the given content text (mirrors test/AiMockSpec.hs).
mockCompletion :: Text -> Chat.ChatCompletionObject
mockCompletion contentText =
    Chat.ChatCompletionObject
        { Chat.id = "test-id"
        , Chat.choices =
            V.fromList
                [ Chat.Choice
                    { finish_reason = "stop"
                    , index = 0
                    , message =
                        Chat.Assistant
                            { Chat.assistant_content = Just contentText
                            , Chat.refusal = Nothing
                            , Chat.name = Nothing
                            , Chat.assistant_audio = Nothing
                            , Chat.tool_calls = Nothing
                            , Chat.extra = Nothing
                            }
                    , Chat.logprobs = Nothing
                    }
                ]
        , Chat.created = 0
        , Chat.model = "test-model"
        , Chat.reasoning_effort = Nothing
        , Chat.service_tier = Nothing
        , Chat.system_fingerprint = Nothing
        , Chat.object = "chat.completion"
        , Chat.usage = Usage 0 0 0 Nothing Nothing
        }

-- | A bot text-message observation addressed to chat 1.
tgMsg :: Text -> MessageId -> Observation ()
tgMsg txt mid = ObsTgMessage{obsChatId = Just (ChatId 1), obsText = txt, obsMsgId = mid}

-- | Predicate: an observation is a bot text message carrying the given text.
isTextReply :: Text -> Observation app -> Bool
isTextReply txt obs = case obs of
    ObsTgMessage{obsText = t} -> t == txt
    _ -> False

-- | Wait budget for the fast-failing timeout tests: 20 ms, far below any
-- legitimate wake-up latency, so the timeout path stays snappy in CI.
tinyBudgetUs :: Int
tinyBudgetUs = 20_000

spec :: Spec
spec = aroundAll withJournalApp $
    describe "Observation journal (tcJournal)" $ do
        it "journals two ObsTgMessage entries in commit order with ids matching the mailbox" $ \app -> do
            journal <- newObservationLog :: IO (ObservationLog ())
            let cfg = defaultTestConfig{tcJournal = Just journal}
            (mocks, _) <-
                runWithDefaultConfig app cfg $
                    runScenarioProgram $ do
                        sendTo (ChatId 1) "first"
                        sendTo (ChatId 1) "second"

            observed <- readObservations journal
            observed
                `shouldBe` [ ObsTgMessage{obsChatId = Just (ChatId 1), obsText = "first", obsMsgId = MessageId 0}
                           , ObsTgMessage{obsChatId = Just (ChatId 1), obsText = "second", obsMsgId = MessageId 1}
                           ]

            -- journal message ids are consistent with the mailbox contents
            msgs <- readOutgoingMailbox mocks
            map omMessageId msgs `shouldBe` [Just mid | ObsTgMessage{obsMsgId = mid} <- observed]

        it "journals an edit, a reaction, and a deletion after the send, in commit order" $ \app -> do
            journal <- newObservationLog :: IO (ObservationLog ())
            let cfg = defaultTestConfig{tcJournal = Just journal}
                botMsgId = MessageId 0
                editReq =
                    (defEditMessageText "inline-placeholder")
                        { editMessageTextChatId = Just (SomeChatId (ChatId 1))
                        , editMessageTextMessageId = Just botMsgId
                        , editMessageTextText = "final text"
                        }
            _ <-
                runWithDefaultConfig app cfg $
                    runScenarioProgram $ do
                        sendTo (ChatId 1) "draft"
                        void $ evalScript $ tgScript "demo-bot" $ Tg.editMessageText editReq
                        void $
                            evalScript $
                                tgScript "demo-bot" $
                                    Tg.setMessageReaction (defSetMessageReaction (SomeChatId (ChatId 1)) botMsgId)
                        void $ evalScript $ tgScript "demo-bot" $ Tg.deleteMessage (ChatId 1) botMsgId

            observed <- readObservations journal
            observed
                `shouldBe` [ ObsTgMessage{obsChatId = Just (ChatId 1), obsText = "draft", obsMsgId = MessageId 0}
                           , ObsTgEdit{obsTargetMsgId = Just (MessageId 0), obsNewText = "final text"}
                           , ObsTgReaction{obsTargetMsgId = Just (MessageId 0)}
                           , ObsTgDelete{obsTargetMsgId = Just (MessageId 0)}
                           ]

        it "journals ObsAsyncScheduled for a runAsync capture in Mocked mode" $ \app -> do
            journal <- newObservationLog :: IO (ObservationLog ())
            let cfg = defaultTestConfig{tcJournal = Just journal}
            _ <-
                runWithDefaultConfig app cfg $
                    runScenarioProgram $
                        runAsync $ sendTo (ChatId 1) "later"

            observed <- readObservations journal
            observed `shouldBe` [ObsAsyncScheduled{obsScenarioDesc = "runAsync scenario"}]

        it "applies tcMailHook and journals the resulting ObsApp" $ \app -> do
            journal <- newObservationLog
            let cfg = defaultTestConfig{tcJournal = Just journal, tcMailHook = Just (const (ObsApp ()))}
            _ <-
                runWithDefaultConfig app cfg $
                    runScenarioProgram $
                        evalScript $
                            mailScript $
                                Mail.sendMail (emptyMail (Address Nothing "test@example.com"))

            observed <- readObservations journal
            observed `shouldBe` [ObsApp ()]

        it "applies tcAiHook with the canned assistant text and journals it" $ \app -> do
            journal <- newObservationLog
            let cfg = defaultTestConfig{tcJournal = Just journal, tcAiHook = Just (\_req reply -> ObsApp reply)}
            mocks <- makeMocksWithAi [mockCompletion "{\"a\":4}"]
            _ <- runWithConfig app cfg mocks $ runScenarioProgram (evalScript askScript)

            observed <- readObservations journal
            observed `shouldBe` [ObsApp "{\"a\":4}"]

        describe "awaitObservation (consumed-set-based wait)" $ do
            it "wakes for a FUTURE observation appended from another thread and records the match as consumed" $ \_app -> do
                st0 <- newScenarioState :: IO (ScenarioState ())
                let journal = ssLog st0
                    producer =
                        threadDelay 30_000
                            >> atomically (appendObservation journal (tgMsg "late" (MessageId 0)))
                withAsync producer $ \_ -> do
                    result <- awaitObservation defaultAwaitBudgetUs st0 (isTextReply "late") "the late reply"
                    case result of
                        Left err -> expectationFailure ("expected a match, timed out: " <> show err)
                        Right (obs, st1) -> do
                            obs `shouldBe` tgMsg "late" (MessageId 0)
                            ssConsumed st1 `shouldBe` Set.singleton 0

            it "keeps a selectively-skipped observation available to a SEQUENTIAL second wait with a different predicate" $ \_app -> do
                st0 <- newScenarioState :: IO (ScenarioState ())
                let journal = ssLog st0
                atomically $ do
                    appendObservation journal (tgMsg "first" (MessageId 0))
                    appendObservation journal (tgMsg "second" (MessageId 1))
                -- the first wait is selective: only the second message matches,
                -- so entry 1 is consumed while the first message (entry 0)
                -- stays unconsumed, even though the wait scanned past it
                result1 <- awaitObservation defaultAwaitBudgetUs st0 (isTextReply "second") "the second reply"
                case result1 of
                    Left err -> expectationFailure ("expected a match, timed out: " <> show err)
                    Right (obs1, st1) -> do
                        obs1 `shouldBe` tgMsg "second" (MessageId 1)
                        ssConsumed st1 `shouldBe` Set.singleton 1
                        -- the second wait runs SEQUENTIALLY from st1 with a
                        -- different predicate: the whole log is scanned in
                        -- commit order, the consumed entry 1 is skipped, and
                        -- the skipped observation is matched and consumed
                        result2 <- awaitObservation defaultAwaitBudgetUs st1 (isTextReply "first") "the first reply"
                        case result2 of
                            Left err -> expectationFailure ("expected a match, timed out: " <> show err)
                            Right (obs2, st2) -> do
                                obs2 `shouldBe` tgMsg "first" (MessageId 0)
                                ssConsumed st2 `shouldBe` Set.fromList [0, 1]

            it "fails with an explicit AwaitTimeout error when the budget expires" $ \_app -> do
                st0 <- newScenarioState :: IO (ScenarioState ())
                let journal = ssLog st0
                atomically (appendObservation journal (tgMsg "present" (MessageId 0)))
                result <- awaitObservation tinyBudgetUs st0 (isTextReply "never-sent") "a never-sent reply"
                case result of
                    Left AwaitTimeout{awaitTimeoutAwaited = awaited, awaitTimeoutBudgetUs = budget} -> do
                        awaited `shouldBe` "a never-sent reply"
                        budget `shouldBe` tinyBudgetUs
                    Right _ -> expectationFailure "expected a timeout, got a match"

            it "leaves the consumed set and journal untouched by a non-matching wait that times out" $ \_app -> do
                st0 <- newScenarioState :: IO (ScenarioState ())
                let journal = ssLog st0
                atomically (appendObservation journal (tgMsg "only" (MessageId 0)))
                _ <- awaitObservation tinyBudgetUs st0 (isTextReply "never-sent") "a never-sent reply"
                -- the failed wait consumed nothing: the very same state still
                -- finds the entry, and the journal was not mutated by the scans
                result <- awaitObservation defaultAwaitBudgetUs st0 (isTextReply "only") "the only reply"
                case result of
                    Left err -> expectationFailure ("expected a match, timed out: " <> show err)
                    Right (obs, st1) -> do
                        obs `shouldBe` tgMsg "only" (MessageId 0)
                        ssConsumed st1 `shouldBe` Set.singleton 0
                readObservations journal `shouldReturn` [tgMsg "only" (MessageId 0)]

            it "peekLastConsumed reads the last consumed entry without waiting or consuming anything new (And-continuation)" $ \_app -> do
                st0 <- newScenarioState :: IO (ScenarioState ())
                peekLastConsumed st0 `shouldReturn` Nothing
                let journal = ssLog st0
                atomically $ do
                    appendObservation journal (tgMsg "one" (MessageId 0))
                    appendObservation journal (tgMsg "two" (MessageId 1))
                result <- awaitObservation defaultAwaitBudgetUs st0 (isTextReply "two") "the second reply"
                case result of
                    Left err -> expectationFailure ("expected a match, timed out: " <> show err)
                    Right (_, st1) -> do
                        -- the consumed set is the source of truth: the peek returns
                        -- exactly the last consumed entry, and repeating it changes nothing
                        peekLastConsumed st1 `shouldReturn` Just (Sequenced 1 (tgMsg "two" (MessageId 1)))
                        peekLastConsumed st1 `shouldReturn` Just (Sequenced 1 (tgMsg "two" (MessageId 1)))
                        case ssDialog st1 of
                            DialogState{dsLastReply = mreply} -> mreply `shouldBe` Just "two"
                        -- the consumed set is {1}: a subsequent wait still scans
                        -- past it, so the entry at 0 remains unconsumed and the
                        -- new entry at 2 is matched
                        atomically (appendObservation journal (tgMsg "three" (MessageId 2)))
                        result3 <- awaitObservation defaultAwaitBudgetUs st1 (isTextReply "three") "the third reply"
                        case result3 of
                            Left err -> expectationFailure ("expected a match, timed out: " <> show err)
                            Right (obs3, st2) -> do
                                obs3 `shouldBe` tgMsg "three" (MessageId 2)
                                ssConsumed st2 `shouldBe` Set.fromList [1, 2]
                                ssLastConsumed st2 `shouldBe` Just 2
