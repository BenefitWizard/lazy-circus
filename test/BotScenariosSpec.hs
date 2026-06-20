{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Integration tests for all BotScenarios scenario functions.
module BotScenariosSpec (spec) where

import BotScenarios
    ( askAgent
    , askAgentContinuing
    , createActWithReaction
    , deleteAct
    , generateReaction
    , getAct
    , listActs
    )
import Common
import Control.Exception qualified as E
import DemoEnv (DemoConfig(..), defaultDemoConfig, withDemoApp)
import LazyCircus (tgScript)
import LazyCircus.AI (conversationFromTurns, emptyConversation, unConversation)
import LazyCircus.App.Log (AppLogMsg(..), AppLogMsgWithContext(..), LoggingContext(..))
import LazyCircus.Testing.Performer
    ( readLog
    , readLogWithContext
    , readScheduledScenarios
    , readScheduledTgRequests
    , readSentMails
    , readTgRequests
    , runScenarioProgram
    , runWithDefaultMocks
    , runWithMocks
    )
import LazyCircus.App.Default (DefaultApp)
import SimpleServiceLib (AllServices)
import LazyCircus.Performer.Default (NoBotConfigured(..))
import LazyCircus.Scenario (evalScript)
import LazyCircus.Scene.Telegram.Lang (getBotName, scheduleMessage, sendDocument, sendMessage)
import LazyCircus.Telegram.Types (WithImportance(..))
import Network.Mail.Mime (Address(..))
import OpenAI.V1.Chat.Completions qualified as Chat
import RIO
import RIO.List (find)
import RIO.Map qualified as M
import RIO.Vector qualified as V
import Data.Text qualified as T
import Test.Hspec
import Telegram.Bot.API (ChatId(..), Response(..), SomeChatId(..), defSendMessage)
import Telegram.Bot.API.Methods.SendDocument (defSendDocument, DocumentFile(..))
import Telegram.Bot.API.Types (FileId(..), InputFile(..))

-- | Minimal configuration sufficient for running scenario tests without Telegram or AI.
-- PRE-CONTRACT: PostgreSQL must be reachable at 127.0.0.1:5432.
-- POST-CONTRACT: withDemoApp will produce a usable DefaultApp.
testConfig :: DemoConfig
testConfig =
    defaultDemoConfig
        { cfgSmtpLogin = "test@example.com"
        , cfgSmtpName = "Test"
        }

-- | Demo configuration that also provides one Telegram bot for test capture.
botTestConfig :: DemoConfig
botTestConfig =
    testConfig
        { cfgTgToken = Just "123456:test-token"
        }

-- | Run a scenario action with a DefaultApp obtained from withDemoApp.
-- Uses aroundAll so the database is set up once for all tests.
withTestApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withTestApp action = withDemoApp testConfig $ \app -> action app

-- | Run a scenario action with a DefaultApp that has one configured Telegram bot.
withBotTestApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withBotTestApp action = withDemoApp botTestConfig $ \app -> action app

spec :: Spec
spec = do
    aroundAll withTestApp $ do
        describe "createActWithReaction" $ do
            it "creates an act in DB and returns it with correct fields" $ \app -> do
                (_, act) <- runWithDefaultMocks app $ do
                    runScenarioProgram $
                        createActWithReaction "Fire Breathing" "Breathes fire"
                            (Address Nothing "test@example.com")

                circusActName act `shouldBe` "Fire Breathing"
                circusActDescription act `shouldBe` "Breathes fire"
                circusId act `shouldBe` 1
                circusActAudienceReaction act `shouldBe` Nothing

            it "captures async mail work instead of executing it immediately" $ \app -> do
                (mocks, _act) <- runWithDefaultMocks app $ do
                    runScenarioProgram $
                        createActWithReaction "Juggling" "Juggling balls"
                            (Address Nothing "notify@example.com")

                sentBefore <- readSentMails mocks
                sentBefore `shouldSatisfy` null

                scheduled <- readScheduledScenarios mocks
                length scheduled `shouldBe` 1

                mapM_ (\scenario -> void $ runWithMocks app mocks $ runScenarioProgram scenario) scheduled

                sentAfter <- readSentMails mocks
                length sentAfter `shouldBe` 1

            it "captures scenario log context during creation" $ \app -> do
                (mocks, _act) <- runWithDefaultMocks app $ do
                    runScenarioProgram $
                        createActWithReaction "Clowns" "Funny clowns"
                            (Address Nothing "test@example.com")

                logs <- readLog mocks
                any (isLogContaining "Creating act") logs `shouldBe` True
                any (isLogContaining "AI returned no response") logs `shouldBe` True

                contextualLogs <- readLogWithContext mocks
                case find (isLogContaining "Creating act" . logMsg) contextualLogs of
                    Nothing -> expectationFailure "Expected contextual log entry for act creation"
                    Just (AppLogMsgWithContext _ (LogContext ctx) mCallSite) -> do
                        M.lookup "lang" ctx `shouldBe` Just "Scenario"
                        M.lookup "act_name" ctx `shouldBe` Just "Clowns"
                        mCallSite `shouldSatisfy` isJust

        describe "listActs" $ do
            it "returns acts from the database" $ \app -> do
                (_, acts) <- runWithDefaultMocks app $ do
                    runScenarioProgram listActs
                acts `shouldSatisfy` (not . null)
                all (\a -> circusActId a > 0 && circusActName a /= "") acts `shouldBe` True

            it "returns acts after creating some" $ \app -> do
                _ <- runWithDefaultMocks app $ do
                    runScenarioProgram $
                        createActWithReaction "Lions" "Taming lions"
                            (Address Nothing "test@example.com")

                (_, acts) <- runWithDefaultMocks app $ do
                    runScenarioProgram listActs

                acts `shouldSatisfy` (not . null)
                any ((== "Lions") . circusActName) acts `shouldBe` True

        describe "getAct" $ do
            it "returns Nothing for a non-existent id" $ \app -> do
                (_, result) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ getAct 99999
                result `shouldBe` Nothing

            it "returns Just act for an existing id" $ \app -> do
                (_, created) <- runWithDefaultMocks app $ do
                    runScenarioProgram $
                        createActWithReaction "Trapeze" "High wire act"
                            (Address Nothing "test@example.com")

                let actId = circusActId created

                (_, found) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ getAct actId
                found `shouldBe` Just created

        describe "generateReaction" $ do
            it "returns Nothing for a non-existent act" $ \app -> do
                (_, result) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ generateReaction 99999
                result `shouldBe` Nothing

            it "returns Nothing when AI returns Nothing (test environment)" $ \app -> do
                (_, created) <- runWithDefaultMocks app $ do
                    runScenarioProgram $
                        createActWithReaction "Magic" "Magic tricks"
                            (Address Nothing "test@example.com")

                let actId = circusActId created

                (_, result) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ generateReaction actId
                result `shouldBe` Nothing

            it "logs a warning when act is not found" $ \app -> do
                (mocks, _) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ generateReaction 99999
                logs <- readLog mocks
                any (isLogContaining "Act not found") logs `shouldBe` True

            it "logs a warning when AI returns no response" $ \app -> do
                (_, created) <- runWithDefaultMocks app $ do
                    runScenarioProgram $
                        createActWithReaction "Piano" "Piano performance"
                            (Address Nothing "test@example.com")

                let actId = circusActId created

                (mocks, _) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ generateReaction actId
                logs <- readLog mocks
                any (isLogContaining "AI returned no response") logs `shouldBe` True

        describe "deleteAct" $ do
            it "removes an existing act" $ \app -> do
                (_, created) <- runWithDefaultMocks app $ do
                    runScenarioProgram $
                        createActWithReaction "Elephants" "Elephant parade"
                            (Address Nothing "test@example.com")

                let actId = circusActId created

                (_, before) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ getAct actId
                before `shouldSatisfy` isJust

                _ <- runWithDefaultMocks app $ do
                    runScenarioProgram $ deleteAct actId

                (_, after) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ getAct actId
                after `shouldBe` Nothing

        describe "Telegram bot configuration" $ do
            it "throws NoBotConfigured when a scenario references an absent bot" $ \app -> do
                result <-
                    E.try @NoBotConfigured $
                        runWithDefaultMocks app $
                            runScenarioProgram $
                                evalScript $ tgScript "missing-bot" getBotName

                case result of
                    Left (NoBotConfigured botName) -> botName `shouldBe` "missing-bot"
                    Right _ -> expectationFailure "Expected NoBotConfigured"

        describe "askAgent" $ do
            it "returns Nothing in test environment (solveWithAgent' defaults to Nothing)" $ \app -> do
                (_, result) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ askAgent "What is 2 + 2?"
                result `shouldBe` Nothing

            it "logs agent processing query" $ \app -> do
                (mocks, _) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ askAgent "Calculate 15 + 27"
                logs <- readLog mocks
                any (isLogContaining "Agent: processing query") logs `shouldBe` True

            it "logs warning when agent returns no response" $ \app -> do
                (mocks, _) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ askAgent "What is 2 + 2?"
                logs <- readLog mocks
                any (isLogContaining "Agent: no response") logs `shouldBe` True

            it "adds query to log context" $ \app -> do
                (mocks, _) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ askAgent "Test query text"
                contextualLogs <- readLogWithContext mocks
                case find (isLogContaining "Agent: processing query" . logMsg) contextualLogs of
                    Nothing -> expectationFailure "Expected contextual log entry for query processing"
                    Just (AppLogMsgWithContext _ (LogContext ctx) _) ->
                        M.lookup "query" ctx `shouldBe` Just "Test query text"

        describe "askAgentContinuing" $ do
            it "returns (Nothing, emptyConversation) in the test environment" $ \app -> do
                (_, (mResp, conv)) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ askAgentContinuing emptyConversation "What is 2 + 2?"
                mResp `shouldBe` Nothing
                V.length (unConversation conv) `shouldBe` 0

            it "keeps the input Conversation unchanged when the agent yields no result (last-known-good)" $ \app -> do
                let userTurn :: Chat.Message (Vector Chat.Content)
                    userTurn = Chat.User
                        { content = V.singleton (Chat.Text "previous")
                        , name = Nothing
                        , extra = Nothing
                        }
                    c1 = conversationFromTurns (V.singleton userTurn)
                (_, (mResp, returnedConv)) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ askAgentContinuing c1 "follow up"
                mResp `shouldBe` Nothing
                V.length (unConversation returnedConv) `shouldBe` V.length (unConversation c1)

            it "logs the continuing processing marker" $ \app -> do
                (mocks, _) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ askAgentContinuing emptyConversation "Calculate 15 + 27"
                logs <- readLog mocks
                any (isLogContaining "Agent: processing query") logs `shouldBe` True

    aroundAll withBotTestApp $ do
        describe "Telegram capture" $ do
            it "captures immediate and scheduled Telegram requests for configured bots" $ \app -> do
                let immediateRequest = defSendMessage (SomeChatId $ ChatId 777) "Hello from tests"
                    scheduledRequest = defSendMessage (SomeChatId $ ChatId 777) "Later from tests"

                (mocks, botName) <- runWithDefaultMocks app $ do
                    runScenarioProgram $ do
                        resolvedBotName <- evalScript $ tgScript "demo-bot" getBotName
                        _ <- evalScript $ tgScript "demo-bot" $ sendMessage immediateRequest
                        evalScript $ tgScript "demo-bot" $ scheduleMessage scheduledRequest
                        pure resolvedBotName

                botName `shouldBe` "demo-bot"

                tgRequests <- readTgRequests mocks
                case tgRequests of
                    [Regular _request] -> pure ()
                    [_] -> expectationFailure "Expected captured request with Regular importance"
                    _ -> expectationFailure "Expected exactly one immediate Telegram request"

                scheduledRequests <- readScheduledTgRequests mocks
                length scheduledRequests `shouldBe` 1

            it "sendDocument returns canned response from mock" $ \app -> do
                let docRequest =
                        defSendDocument
                            (SomeChatId $ ChatId 777)
                            (MakeDocumentFile $ InputFileId $ FileId "test-file-id")
                (_, resp) <- runWithDefaultMocks app $ do
                    runScenarioProgram $
                        evalScript $ tgScript "demo-bot" $ sendDocument docRequest
                responseOk resp `shouldBe` True


-- | Check whether a log message contains the given substring.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Returns True when any AppLogMsg variant contains the text.
isLogContaining :: Text -> AppLogMsg -> Bool
isLogContaining target = \case
    AppLogMsg t       -> target `T.isInfixOf` t
    SensitiveLogMsg t -> target `T.isInfixOf` t
    ErrorLogMsg t     -> target `T.isInfixOf` t
    WarnLogMsg t      -> target `T.isInfixOf` t
