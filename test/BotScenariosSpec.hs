{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Integration tests for all BotScenarios scenario functions.
module BotScenariosSpec (spec) where

import BotScenarios
    ( createActWithReaction
    , listActs
    , getAct
    , generateReaction
    , deleteAct
    )
import Common
import DemoEnv (DemoConfig(..), withDemoApp)
import LazyCircus.App.Log (AppLogMsg(..))
import LazyCircus.Testing.Performer
    ( runWithDefaultMocks
    , readLog
    , readScheduledScenarios
    , runScenarioProgram
    )
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.App.Service (NoServiceLib)
import Network.Mail.Mime (Address(..))
import RIO
import Data.Text qualified as T
import Test.Hspec

-- | Minimal configuration sufficient for running scenario tests without Telegram or AI.
-- PRE-CONTRACT: PostgreSQL must be reachable at 127.0.0.1:5432.
-- POST-CONTRACT: withDemoApp will produce a usable DefaultApp.
testConfig :: DemoConfig
testConfig = DemoConfig
    { cfgTgToken = Nothing
    , cfgTgChatId = Nothing
    , cfgAiApiKey = Nothing
    , cfgAiBaseUrl = Nothing
    , cfgSmtpHost = "127.0.0.1"
    , cfgSmtpPort = 1025
    , cfgSmtpLogin = "test@example.com"
    , cfgSmtpPass = ""
    , cfgSmtpName = "Test"
    , cfgSmtpUseTls = False
    , cfgNotificationEmail = Nothing
    }

-- | Run a scenario action with a DefaultApp obtained from withDemoApp.
-- Uses aroundAll so the database is set up once for all tests.
withTestApp :: (DefaultApp NoServiceLib -> IO ()) -> IO ()
withTestApp action = withDemoApp testConfig $ \app -> action app

spec :: Spec
spec = aroundAll withTestApp $ do
    describe "createActWithReaction" $ do
        it "creates an act in DB and returns it with correct fields" $ \app -> do
            (mocks, act) <- runWithDefaultMocks app $ do
                runScenarioProgram $
                    createActWithReaction "Fire Breathing" "Breathes fire"
                        (Address Nothing "test@example.com")

            circusActName act `shouldBe` "Fire Breathing"
            circusActDescription act `shouldBe` "Breathes fire"
            circusId act `shouldBe` 1
            -- AI returns Nothing in tests, so no audience reaction is set
            circusActAudienceReaction act `shouldBe` Nothing

        it "schedules an email notification via runAsync" $ \app -> do
            (mocks, _act) <- runWithDefaultMocks app $ do
                runScenarioProgram $
                    createActWithReaction "Juggling" "Juggling balls"
                        (Address Nothing "notify@example.com")

            scheduled <- readScheduledScenarios mocks
            length scheduled `shouldSatisfy` (> 0)

        it "logs expected messages during creation" $ \app -> do
            (mocks, _act) <- runWithDefaultMocks app $ do
                runScenarioProgram $
                    createActWithReaction "Clowns" "Funny clowns"
                        (Address Nothing "test@example.com")

            logs <- readLog mocks
            any (isLogContaining "Creating act") logs `shouldBe` True
            any (isLogContaining "AI returned no response") logs `shouldBe` True

    describe "listActs" $ do
        it "returns acts from the database" $ \app -> do
            (_, acts) <- runWithDefaultMocks app $ do
                runScenarioProgram listActs
            -- The shared test DB may already contain acts from other tests
            acts `shouldSatisfy` (not . null)
            all (\a -> circusActId a > 0 && circusActName a /= "") acts `shouldBe` True

        it "returns acts after creating some" $ \app -> do
            -- Create an act first
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
            -- Create an act to get a valid id
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
            -- Create an act
            (_, created) <- runWithDefaultMocks app $ do
                runScenarioProgram $
                    createActWithReaction "Elephants" "Elephant parade"
                        (Address Nothing "test@example.com")

            let actId = circusActId created

            -- Verify it exists
            (_, before) <- runWithDefaultMocks app $ do
                runScenarioProgram $ getAct actId
            before `shouldSatisfy` isJust

            -- Delete it
            _ <- runWithDefaultMocks app $ do
                runScenarioProgram $ deleteAct actId

            -- Verify it's gone
            (_, after) <- runWithDefaultMocks app $ do
                runScenarioProgram $ getAct actId
            after `shouldBe` Nothing

-- | Check whether a log message contains the given substring.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Returns True when any AppLogMsg variant contains the text.
isLogContaining :: Text -> AppLogMsg -> Bool
isLogContaining target = \case
    AppLogMsg t       -> target `T.isInfixOf` t
    SensitiveLogMsg t -> target `T.isInfixOf` t
    ErrorLogMsg t     -> target `T.isInfixOf` t
    WarnLogMsg t      -> target `T.isInfixOf` t
