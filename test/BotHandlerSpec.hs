{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Scenario-level tests for 'BotHandler.handleScenario'.
--
-- Routing and dialog logic are exercised end-to-end through the TelegramScript
-- DSL under the test performer: outgoing replies are captured via
-- 'readTgRequests' and the returned 'Model' is asserted against the expected
-- 'ChatState'.
module BotHandlerSpec (spec) where

import RIO
import RIO.Text qualified as Text
import Test.Hspec

import BotApp (ChatState (..), Model (..))
import BotHandler (BotHandlerConfig (..), handleScenario, runUpdate)
import ChatStateStore (newChatStateStore)
import DemoEnv (DemoConfig (..), defaultDemoConfig, withDemoApp)
import LazyCircus.AI (emptyConversation)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Testing.Performer
    ( Mocks
    , OutgoingKind (..)
    , OutgoingMessage (..)
    , defaultTestConfig
    , makeMocks
    , readOutgoingMailbox
    , readTgRequests
    , runScenarioProgram
    , runWithConfig
    , runWithDefaultMocks
    )
import LazyCircus.Testing.Updates
    ( defaultTestUserId
    , mkNonTextMessageUpdate
    , mkPollAnswerUpdate
    , mkTextUpdate
    , mkTextUpdateIn
    , newUpdateFactory
    )
import LazyCircus.Telegram.Types (WithImportance (..))
import PollRegistry (PollRegistry, lookupPollChat, newPollRegistry)
import SimpleServiceLib (AllServices)
import Telegram.Bot.API (ChatId (..), SendMessageRequest, Update, sendMessageText)
import Telegram.Bot.API.Types (PollId (..))

-- | Bot handler config pointing at the @demo-bot@ registered by 'botTestConfig'.
testConfig :: PollRegistry -> BotHandlerConfig
testConfig pollRegistry = BotHandlerConfig
    { bhcBotName = "demo-bot"
    , bhcNotificationEmail = Nothing
    , bhcPollRegistry = pollRegistry
    }

-- | Demo configuration that registers one Telegram bot (@demo-bot@) so that
-- 'handleScenario' replies (which go through @tgScript "demo-bot"@) can be
-- captured by the test performer.
botTestConfig :: DemoConfig
botTestConfig = defaultDemoConfig{cfgTgToken = Just "123456:test-token"}

-- | Run a test action with a 'DefaultApp' that has the @demo-bot@ configured.
withBotTestApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withBotTestApp action = withDemoApp botTestConfig $ \app -> action app

-- | Initial idle model used as the default chat state for routing tests.
idleModel :: Model
idleModel = Model Idle emptyConversation

spec :: Spec
spec = aroundAll withBotTestApp $ do
    describe "handleScenario" $ do
        it "replies to /start with the welcome text" $ \app -> do
            (mocks, newModel) <- runHandler app idleModel (mkTextUpdate "/start")
            replies <- capturedReplies mocks
            replies `shouldSatisfy` (not . null)
            head replies `shouldSatisfy` ("🎪 Welcome to Lazy Circus Bot!" `Text.isPrefixOf`)
            modelChatState newModel `shouldBe` Idle

        it "replies to /newact with the name prompt and enters WaitingForName" $ \app -> do
            (mocks, newModel) <- runHandler app idleModel (mkTextUpdate "/newact")
            head <$> capturedReplies mocks >>= \r -> r `shouldBe` "🎭 Enter act name:"
            modelChatState newModel `shouldBe` WaitingForName

        it "prompts for description and enters WaitingForDescription on free text in WaitingForName" $ \app -> do
            let model = Model WaitingForName emptyConversation
            (mocks, newModel) <- runHandler app model (mkTextUpdate "Fire Juggling")
            head <$> capturedReplies mocks >>= \r -> r `shouldBe` "📝 Enter act description:"
            modelChatState newModel `shouldBe` WaitingForDescription "Fire Juggling"

        it "replies with no-acts-found for /list on an empty database" $ \app -> do
            (mocks, newModel) <- runHandler app idleModel (mkTextUpdate "/list")
            head <$> capturedReplies mocks >>= \r -> r `shouldBe` "📭 No acts found."
            modelChatState newModel `shouldBe` Idle

        it "replies with not-found for /act on an unknown id" $ \app -> do
            (mocks, newModel) <- runHandler app idleModel (mkTextUpdate "/act 999999")
            head <$> capturedReplies mocks >>= \r -> r `shouldBe` "📭 Act not found."
            modelChatState newModel `shouldBe` Idle

        it "replies with could-not-generate for /react on an unknown id" $ \app -> do
            (mocks, newModel) <- runHandler app idleModel (mkTextUpdate "/react 999999")
            replies <- capturedReplies mocks
            replies `shouldSatisfy` (not . null)
            last replies `shouldBe` "Could not generate reaction."
            modelChatState newModel `shouldBe` Idle

        it "replies act-deleted for /delete on an unknown id (idempotent no-op)" $ \app -> do
            (mocks, newModel) <- runHandler app idleModel (mkTextUpdate "/delete 999999")
            head <$> capturedReplies mocks >>= \r -> r `shouldBe` "🗑️ Act deleted."
            modelChatState newModel `shouldBe` Idle

        it "replies with the defensive please-wait message when state is AgentBusy" $ \app -> do
            let model = Model AgentBusy emptyConversation
            (mocks, newModel) <- runHandler app model (mkTextUpdate "anything")
            head <$> capturedReplies mocks >>= \r -> r `shouldBe` "⏳ Still processing your previous message — please wait for the reply, then resend."
            modelChatState newModel `shouldBe` AgentBusy

        it "is a no-op for a message without text (model unchanged, no reply)" $ \app -> do
            (mocks, newModel) <- runHandler app idleModel mkNonTextMessageUpdate
            replies <- capturedReplies mocks
            replies `shouldBe` []
            modelChatState newModel `shouldBe` Idle

        it "runs the agent on free text in Idle and replies (AI mocked to no-response)" $ \app -> do
            (mocks, newModel) <- runHandler app idleModel (mkTextUpdate "What is 2 + 2?")
            replies <- capturedReplies mocks
            replies `shouldSatisfy` (not . null)
            head replies `shouldBe` "🤔 Thinking..."
            last replies `shouldBe` "🤷 I couldn't process your request. Please try again."
            modelChatState newModel `shouldBe` Idle

        it "creates an act on free text in WaitingForDescription and returns to Idle" $ \app -> do
            -- NOTE: this test mutates the shared DB (creates an act); it is placed
            -- last so it cannot affect the /list-on-empty-db assertion above.
            let model = Model (WaitingForDescription "Fire Juggling") emptyConversation
            (mocks, newModel) <- runHandler app model (mkTextUpdate "Breathes fire")
            replies <- capturedReplies mocks
            replies `shouldSatisfy` (not . null)
            head replies `shouldBe` "⏳ Creating act..."
            last replies `shouldSatisfy` ("Fire Juggling" `Text.isInfixOf`)
            modelChatState newModel `shouldBe` Idle

        -- The /poll → poll_answer examples below never touch the database, so
        -- they stay safe after the DB-mutating example above. Each example gets
        -- a FRESH 'PollRegistry' and each handleScenario step a fresh mailbox
        -- (one 'runWithDefaultMocks' per step) so the examples stay independent.

        it "sends a poll on /poll, captures it as OutSendPoll and registers its id" $ \app -> do
            pollRegistry <- newPollRegistry
            (mocks, newModel) <- runHandlerWithRegistry app pollRegistry idleModel (mkTextUpdate "/poll")
            pollCapture <- capturedSendPoll =<< readOutgoingMailbox mocks
            omChatId pollCapture `shouldBe` Just (ChatId 1) -- mkTextUpdate hardcodes chat id 1
            pollId <- capturedPollId pollCapture
            lookupPollChat pollRegistry pollId `shouldReturn` Just (ChatId 1)
            modelChatState newModel `shouldBe` Idle

        it "answers a chat-less poll_answer by notifying the chat the poll was sent to" $ \app -> do
            pollRegistry <- newPollRegistry
            (pollMocks, _) <- runHandlerWithRegistry app pollRegistry idleModel (mkTextUpdate "/poll")
            pollId <- capturedPollId =<< capturedSendPoll =<< readOutgoingMailbox pollMocks
            updateFactory <- newUpdateFactory
            pollAnswer <- mkPollAnswerUpdate updateFactory defaultTestUserId pollId [1]
            -- A poll_answer carries NO chat id: this step only gets past the
            -- handler's updateChatId guard because the poll_answer branch is
            -- dispatched BEFORE it (regression guard for that ordering).
            (mocks, newModel) <- runHandlerWithRegistry app pollRegistry idleModel pollAnswer
            captures <- readOutgoingMailbox mocks
            map omKind captures `shouldBe` [OutSendMessage]
            map omChatId captures `shouldBe` [Just (ChatId 1)]
            case mapM omText captures of
                Just [txt] -> txt `shouldSatisfy` ("выбрал" `Text.isInfixOf`)
                _ -> expectationFailure ("Expected exactly one reply text, got: " <> show captures)
            modelChatState newModel `shouldBe` Idle

        it "drops a poll_answer for an unknown poll without sending anything" $ \app -> do
            pollRegistry <- newPollRegistry
            updateFactory <- newUpdateFactory
            pollAnswer <- mkPollAnswerUpdate updateFactory defaultTestUserId (PollId "nonexistent") [1]
            (mocks, newModel) <- runHandlerWithRegistry app pollRegistry idleModel pollAnswer
            captures <- readOutgoingMailbox mocks
            captures `shouldSatisfy` null
            modelChatState newModel `shouldBe` Idle

    describe "runUpdate" $ do
        it "routes a chat-less poll_answer to the chat the poll was sent to" $ \app -> do
            pollRegistry <- newPollRegistry
            mocks <- makeMocks
            store <- newChatStateStore
            let driver =
                    runUpdate
                        (runWithConfig app (defaultTestConfig @()) mocks . runScenarioProgram)
                        (testConfig pollRegistry)
                        store
            updateFactory <- newUpdateFactory

            -- Step 1: /poll through the shared driver, registering the poll.
            pollCommand <- mkTextUpdateIn updateFactory (ChatId 1) "/poll"
            driver pollCommand

            -- Destructive drain #1: recover the PollId from the OutSendPoll
            -- capture and prove it was registered for the originating chat.
            pollCapture <- capturedSendPoll =<< readOutgoingMailbox mocks
            omChatId pollCapture `shouldBe` Just (ChatId 1)
            pollId <- capturedPollId pollCapture
            lookupPollChat pollRegistry pollId `shouldReturn` Just (ChatId 1)

            -- Step 2: the chat-less poll_answer through the SAME driver. It
            -- only reaches 'handlePollAnswer' because 'runUpdate' dispatches
            -- the poll_answer branch BEFORE its updateChatId guard (which
            -- would otherwise print "Bot update without chat id" and drop it).
            pollAnswer <- mkPollAnswerUpdate updateFactory defaultTestUserId pollId [1, 3]
            driver pollAnswer

            -- Destructive drain #2: exactly one notification to the chat the
            -- poll was sent to (drain #1 already removed the poll traffic).
            captures <- readOutgoingMailbox mocks
            map omKind captures `shouldBe` [OutSendMessage]
            map omChatId captures `shouldBe` [Just (ChatId 1)]
            case mapM omText captures of
                Just [txt] -> txt `shouldSatisfy` ("выбрал" `Text.isInfixOf`)
                _ -> expectationFailure ("Expected exactly one reply text, got: " <> show captures)

-- | Run 'handleScenario' against the given model and update under the test
-- performer, returning the captured mocks and the resulting 'Model'.
-- Each call gets a FRESH 'PollRegistry' so single-update tests never share
-- poll state.
-- PRE-CONTRACT: The 'DefaultApp' has the @demo-bot@ registered.
-- POST-CONTRACT: Returns the mocks and the new 'Model'; the unit result of
-- 'handleScenario' is discarded.
runHandler :: DefaultApp AllServices -> Model -> Update -> IO (Mocks AllServices, Model)
runHandler app model update = do
    pollRegistry <- newPollRegistry
    runHandlerWithRegistry app pollRegistry model update

-- | 'runHandler' with a caller-supplied 'PollRegistry', so one example can
-- drive a multi-update flow (e.g. @/poll@ then @poll_answer@) through a single
-- registry, mirroring the production bot's process-wide registry.
-- PRE-CONTRACT: The 'DefaultApp' has the @demo-bot@ registered.
-- POST-CONTRACT: Returns the mocks and the new 'Model'; the unit result of
-- 'handleScenario' is discarded.
runHandlerWithRegistry :: DefaultApp AllServices -> PollRegistry -> Model -> Update -> IO (Mocks AllServices, Model)
runHandlerWithRegistry app pollRegistry model update = do
    (mocks, (newModel, ())) <- runWithDefaultMocks app $
        runScenarioProgram (handleScenario (testConfig pollRegistry) model update)
    pure (mocks, newModel)

-- | Extract the text of every captured outgoing Telegram send, earliest-first.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Result is ordered earliest-first (matching 'readTgRequests').
capturedReplies :: Mocks serviceLib -> IO [Text]
capturedReplies mocks =
    map (sendMessageText . importanceValue) <$> readTgRequests mocks

-- | Extract the single @sendPoll@ capture from drained outgoing-mailbox traffic.
-- PRE-CONTRACT: The captures come from a step that sent at most one poll.
-- POST-CONTRACT: Fails the example unless exactly one 'OutSendPoll' capture is
-- present; the fallback value is unreachable after 'expectationFailure'.
capturedSendPoll :: [OutgoingMessage] -> IO OutgoingMessage
capturedSendPoll captures = case filter ((== OutSendPoll) . omKind) captures of
    [pollCapture] -> pure pollCapture
    _ -> do
        expectationFailure ("Expected exactly one OutSendPoll capture, got: " <> show captures)
        pure (OutgoingMessage OutSendPoll Nothing Nothing Nothing Nothing)

-- | Recover the 'PollId' the Telegram mock assigned to a captured @sendPoll@.
-- The mock derives the id from its message-id counter (@\"poll-\" <> show mid@),
-- so tests must reconstruct it from the capture instead of hardcoding it.
-- PRE-CONTRACT: The capture is an 'OutSendPoll' with an assigned 'omMessageId'.
-- POST-CONTRACT: Returns the same 'PollId' the mock returned to the handler and
-- the handler registered in the 'PollRegistry'.
capturedPollId :: OutgoingMessage -> IO PollId
capturedPollId pollCapture = case omMessageId pollCapture of
    Just mid -> pure (PollId ("poll-" <> tshow mid))
    Nothing -> do
        expectationFailure ("OutSendPoll capture has no assigned message id: " <> show pollCapture)
        pure (PollId "")

-- | Unwrap a 'WithImportance' payload, discarding the importance marker.
importanceValue :: WithImportance a -> a
importanceValue (Regular a) = a
importanceValue (Important a) = a
