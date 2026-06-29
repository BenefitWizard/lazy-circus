{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Main (main) where

import Network.Mail.Mime (Address (..))
import RIO
import System.Environment (lookupEnv)
import System.Exit (die)
import System.IO (hPutStrLn, putStrLn)

import Telegram.Bot.API (Token (..), defaultTelegramClientEnv)
import Telegram.Bot.Extra.Polling (runPollingBot)

import BotHandler (BotHandlerConfig (..), updateAction)
import ChatStateStore (newChatStateStore)
import DemoEnv (DemoConfig (..), readDemoConfig, withDemoApp)

-- | Retry delay (microseconds) used by 'runPollingBot' when a getUpdates request fails.
retryDelay :: Int
retryDelay = 5_000_000

-- | Entry point: read configuration, initialise the demo app, and start the polling Telegram bot.
main :: IO ()
main = do
    config <- readDemoConfig
    case cfgTgToken config of
        Nothing -> die "TG_TOKEN is required for the bot. Set it in .env"
        Just token -> do
            putStrLn "🎪 Lazy Circus Bot starting..."
            notificationEmail <-
                fmap (fmap (\addr -> Address Nothing (fromString addr))) (lookupEnv "NOTIFICATION_EMAIL")
            store <- newChatStateStore
            withDemoApp config $ \app -> do
                clientEnv <- defaultTelegramClientEnv (Token token)
                let cfg =
                        BotHandlerConfig
                            { bhcBotName = "demo-bot"
                            , bhcNotificationEmail = notificationEmail
                            }
                    onActionError e = hPutStrLn stderr ("Bot action error: " ++ show e)
                putStrLn "🚀 Bot is running. Press Ctrl+C to stop."
                runPollingBot onActionError retryDelay clientEnv (updateAction cfg store app)
