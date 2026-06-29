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
import BotHandler (BotHandlerConfig (..), handleScenario)
import DemoEnv (DemoConfig (..), defaultDemoConfig, withDemoApp)
import LazyCircus.AI (emptyConversation)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Testing.Performer
    ( Mocks
    , readTgRequests
    , runScenarioProgram
    , runWithDefaultMocks
    )
import LazyCircus.Testing.Updates (mkNonTextMessageUpdate, mkTextUpdate)
import LazyCircus.Telegram.Types (WithImportance (..))
import SimpleServiceLib (AllServices)
import Telegram.Bot.API (SendMessageRequest, Update, sendMessageText)

-- | Bot handler config pointing at the @demo-bot@ registered by 'botTestConfig'.
testConfig :: BotHandlerConfig
testConfig = BotHandlerConfig
    { bhcBotName = "demo-bot"
    , bhcNotificationEmail = Nothing
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

-- | Run 'handleScenario' against the given model and update under the test
-- performer, returning the captured mocks and the resulting 'Model'.
-- PRE-CONTRACT: The 'DefaultApp' has the @demo-bot@ registered.
-- POST-CONTRACT: Returns the mocks and the new 'Model'; the unit result of
-- 'handleScenario' is discarded.
runHandler :: DefaultApp AllServices -> Model -> Update -> IO (Mocks AllServices, Model)
runHandler app model update = do
    (mocks, (newModel, ())) <- runWithDefaultMocks app $
        runScenarioProgram (handleScenario testConfig model update)
    pure (mocks, newModel)

-- | Extract the text of every captured outgoing Telegram send, earliest-first.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Result is ordered earliest-first (matching 'readTgRequests').
capturedReplies :: Mocks serviceLib -> IO [Text]
capturedReplies mocks =
    map (sendMessageText . importanceValue) <$> readTgRequests mocks

-- | Unwrap a 'WithImportance' payload, discarding the importance marker.
importanceValue :: WithImportance a -> a
importanceValue (Regular a) = a
importanceValue (Important a) = a
