{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Unit tests for the mock-injection entry point 'tgTestWithMocks': a
caller-owned 'Mocks' set, pre-seeded BEFORE the run, must be the mock set the
run actually observes.

The bot driver consumes a pre-seeded AI answer through the ordinary scene
machinery (@aiScript@ @ask@ under 'LazyCircus.Testing.Performer.runWithConfig'
with the injected mocks) and echoes it into the chat, so the DSL's reply wait
proves both directions of the injection: the bot reads the seeded queue of the
PASSED mocks and the DSL observes the PASSED mocks' outgoing mailbox. A second
example pins the 'TgTestConfigError' guard to the injected-mocks entry point.
No live DB and no live Telegram: the app is the DB-free fixture
'TestSupport.DbFreeApp.mkDbFreeApp' and the performer config is all-mocked.
-}
module LazyCircus.Testing.TgTestSpec (spec) where

import RIO
import RIO.Text qualified as T
import RIO.Vector qualified as V
import Test.Hspec
import TestSupport.DbFreeApp (mkDbFreeApp)

import LazyCircus (tgScript)
import LazyCircus.AI (AIRequest, mkAIRequest)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.App.Service (NoServiceLib (..))
import LazyCircus.Scenario (ScenarioProgram, evalScript)
import LazyCircus.Scene.AI qualified as Scene (ask)
import LazyCircus.Scene.Telegram.Lang qualified as Tg (sendMessage)
import LazyCircus.Script (Script (..))
import LazyCircus.Testing.Performer
    ( AiMock (..)
    , Mocks (..)
    , Mode (..)
    , TestConfig (..)
    , defaultTestConfig
    , makeMocks
    , makeMocksWithAi
    , runScenarioProgram
    , runWithConfig
    )
import LazyCircus.Testing.TgTest
    ( Mailboxes (..)
    , TelegramTestScript
    , TgTestConfig (..)
    , TgTestConfigError (..)
    , defaultTgTestConfig
    , guardWith
    , sendMessage
    , tgTestWithMocks
    , waitForReply
    )
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.Usage (Usage (..))
import Telegram.Bot.API
    ( ChatId
    , SomeChatId (..)
    , Update
    , defSendMessage
    , messageText
    , updateMessage
    )
import Telegram.Bot.API.GettingUpdates (updateChatId)

spec :: Spec
spec = do
    app <- runIO (mkDbFreeApp botName)
    describe "tgTestWithMocks (caller-owned mocks)" $ do
        it "lets the bot and DSL observe AI answers pre-seeded into the mocks before the run" $ do
            -- The marker rides as a JSON string so the bot's @ask@ payload
            -- ('Text') decodes it back verbatim.
            mocks <- makeMocksWithAi [mockCompletion "\"seeded-42\""]
            (mailboxes, result) <-
                tgTestWithMocks defaultTgTestConfig mocks (aiEchoAction app) seededAnswerScript
            case result of
                Left err -> expectationFailure ("run aborted: " <> show err)
                Right () -> pure ()
            -- the reply was consumed from the PASSED mocks' mailbox (the
            -- snapshot shares it), and the request hit the PASSED mocks' AI
            -- queue — different mocks would leave both untouched
            mbOutgoing mailboxes `shouldSatisfy` null
            requests <- readSomeRef (aiRequests (aiMock mocks))
            length requests `shouldBe` 1

        it "rejects a Real-Telegram performer config from the injected-mocks entry point" $ do
            mocks <- makeMocks
            let realTgConfig =
                    defaultTgTestConfig
                        { ttgPerformerConfig = defaultTestConfig{tcTelegram = Real}
                        } :: TgTestConfig ()
            tgTestWithMocks realTgConfig mocks noBot (pure ())
                `shouldThrow` \(TgTestConfigError _) -> True

--------------------------------------------------------------------------------
-- Test stack
--------------------------------------------------------------------------------

-- | The bot name the DB-free app registers (@tgScript@ resolves effects to it).
botName :: Text
botName = "mocks-bot"

-- | The one-shot AI request the test bot issues; the payload is the assistant
-- text the seeded mock returns.
seededAsk :: AIRequest Text
seededAsk = mkAIRequest ["What did the mock seed say?"] ["You repeat the seeded answer verbatim."]

-- | The bot's AI scene: one stateless @ask@ over the injected AI mock queue.
seededAskScript :: Script (Maybe Text)
seededAskScript = AIScriptDef [] (Scene.ask seededAsk)

-- | The test bot's scenario: ask the (mocked) AI and echo its answer into the
-- chat that sent the update.
aiEchoScenario :: ChatId -> ScenarioProgram Script NoServiceLib ()
aiEchoScenario chatId = do
    answer <- evalScript seededAskScript
    case answer of
        Just marker ->
            void $
                evalScript $
                    tgScript botName $
                        Tg.sendMessage (defSendMessage (SomeChatId chatId) ("the seeded answer: " <> marker))
        Nothing -> pure ()

-- | The test bot's buildAction: the ordinary update-driver with the test
-- performer substituted, wired against the SAME mocks 'tgTestWithMocks' hands
-- it — that is the injection contract under test.
aiEchoAction
    :: DefaultApp NoServiceLib
    -> TestConfig ()
    -> Mocks NoServiceLib
    -> IO (Update -> IO ())
aiEchoAction app cfg mocks =
    pure $ \update ->
        case (updateChatId update, updateMessage update >>= messageText) of
            (Just chatId, Just _) ->
                runWithConfig app cfg mocks (runScenarioProgram (aiEchoScenario chatId))
            _ -> pure ()

-- | The DSL run over the pre-seeded mocks: one user turn, then wait for the
-- bot's echo of the seeded answer.
seededAnswerScript :: TelegramTestScript ()
seededAnswerScript = do
    _ <- sendMessage "what is the seeded answer?"
    reply <- waitForReply
    guardWith "expected the bot to echo the pre-seeded AI answer" ("seeded-42" `T.isInfixOf` reply)

-- | A bot driver ignoring every update (used where only the config guard runs).
noBot :: TestConfig () -> Mocks NoServiceLib -> IO (Update -> IO ())
noBot _ _ = pure (\_ -> pure ())

-- | Build a 'Chat.ChatCompletionObject' with a single Assistant choice
-- carrying the given content text (mirrors test/Bdd/JournalSpec.hs).
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
