{-# LANGUAGE OverloadedStrings #-}

-- | Shared demo wiring for the @tgTest@ specs.
--
-- The point of interest here is 'buildDemoAction': it runs the bot's ordinary
-- update-driver ('BotHandler.runUpdate') under the configurable test performer
-- ('LazyCircus.Testing.Performer.runWithConfig', driven by the 'TestConfig'
-- that 'LazyCircus.Testing.TgTest.tgTest' hands it) instead of the production
-- performer. The handler logic ('BotHandler.handleScenario') is exactly what
-- production runs; only the performer is swapped, so Telegram/AI/mail are
-- mocked and replies land in the shared STM mailbox the @tgTest@ DSL observes.
module TestHelpers.Bot
    ( withBotTestApp
    , demoHandlerConfig
    , runDemoTgTest
    ) where

import RIO

import BotHandler (BotHandlerConfig (..), runUpdate)
import ChatStateStore (newChatStateStore)
import DemoEnv (DemoConfig (..), defaultDemoConfig, withDemoApp)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Testing.Performer (Mocks, TestConfig, runScenarioProgram, runWithConfig)
import LazyCircus.Testing.TgTest
    ( Mailboxes
    , TgTestError
    , TelegramTestScript
    , defaultTgTestConfig
    , tgTest
    )
import SimpleServiceLib (AllServices)
import Telegram.Bot.API (Update)

-- | Handler config pointing at the @demo-bot@ registered by 'botTestConfig'.
demoHandlerConfig :: BotHandlerConfig
demoHandlerConfig =
    BotHandlerConfig
        { bhcBotName = "demo-bot"
        , bhcNotificationEmail = Nothing
        }

-- | Demo configuration that registers one Telegram bot (@demo-bot@) so that the
-- handler's @tgScript "demo-bot"@ replies are captured by the test performer.
botTestConfig :: DemoConfig
botTestConfig = defaultDemoConfig{cfgTgToken = Just "123456:test-token"}

-- | Run an action with a 'DefaultApp' that has @demo-bot@ configured.
withBotTestApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withBotTestApp action = withDemoApp botTestConfig $ \app -> action app

-- | Build the demo bot's @Update -> IO ()@ action under the test performer.
-- The bot runs its ordinary script ('runUpdate' + 'handleScenario'); only the
-- performer is the test performer (configured by the supplied 'TestConfig'), so
-- every Telegram side effect is mocked and captured in the shared mailbox.
buildDemoAction :: DefaultApp AllServices -> TestConfig app -> Mocks AllServices -> IO (Update -> IO ())
buildDemoAction app cfg mocks = do
    store <- newChatStateStore
    pure $ runUpdate (runWithConfig app cfg mocks . runScenarioProgram) demoHandlerConfig store

-- | Run a DSL script via 'tgTest' against the demo app and return the snapshot + result.
runDemoTgTest :: DefaultApp AllServices -> TelegramTestScript a -> IO (Mailboxes, Either TgTestError a)
runDemoTgTest app = tgTest defaultTgTestConfig (buildDemoAction app)
