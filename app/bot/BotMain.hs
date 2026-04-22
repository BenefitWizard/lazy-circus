{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Main where

import Network.Mail.Mime (Address (..))
import RIO
import System.Environment (lookupEnv)
import System.Exit (die)
import System.IO (putStrLn)

import Telegram.Bot.API (Token (..), defaultTelegramClientEnv)
import Telegram.Bot.API.GettingUpdates (updateChatId)
import Telegram.Bot.Simple (conversationBot, startBot_)
import Telegram.Bot.Simple.UpdateParser ()

import BotApp (makeBot)
import DemoEnv (DemoConfig (..), readDemoConfig, withDemoApp)

-- | Entry point: read configuration, initialise the demo app, and start the Telegram bot.
main :: IO ()
main = do
    config <- readDemoConfig
    case cfgTgToken config of
        Nothing -> die "TG_TOKEN is required for the bot. Set it in .env"
        Just token -> do
            putStrLn "🎪 Lazy Circus Bot starting..."
            notificationEmail <- fmap (fmap (\addr -> Address Nothing (fromString addr))) (lookupEnv "NOTIFICATION_EMAIL")
            withDemoApp config $ \app -> do
                tgEnv <- defaultTelegramClientEnv (Token token)
                let bot = makeBot app notificationEmail
                putStrLn "🚀 Bot is running. Press Ctrl+C to stop."
                startBot_ (conversationBot updateChatId bot) tgEnv
