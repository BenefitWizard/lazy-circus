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
import LazyCircus.Telegram.Stars (StarsPackage (..))
import PollRegistry (newPollRegistry)

-- | Retry delay (microseconds) used by 'runPollingBot' when a getUpdates request fails.
retryDelay :: Int
retryDelay = 5_000_000

-- | Demo Stars top-up packages: 50\/100\/250 Stars at a flat demo fiat rate of
-- 10 minor units per Star (the fiat figures are demo-only; Stars invoices are
-- priced purely in XTR).
demoStarsPackages :: [StarsPackage]
demoStarsPackages =
    [ StarsPackage "50 Stars" "Support the circus with 50 Stars" "topup-50" 50 500
    , StarsPackage "100 Stars" "Support the circus with 100 Stars" "topup-100" 100 1000
    , StarsPackage "250 Stars" "Support the circus with 250 Stars" "topup-250" 250 2500
    ]

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
            pollRegistry <- newPollRegistry
            withDemoApp config $ \app -> do
                clientEnv <- defaultTelegramClientEnv (Token token)
                let cfg =
                        BotHandlerConfig
                            { bhcBotName = "demo-bot"
                            , bhcNotificationEmail = notificationEmail
                            , bhcPollRegistry = pollRegistry
                            , bhcStarsPackages = demoStarsPackages
                            }
                    onActionError e = hPutStrLn stderr ("Bot action error: " ++ show e)
                putStrLn "🚀 Bot is running. Press Ctrl+C to stop."
                runPollingBot onActionError retryDelay clientEnv (updateAction cfg store app)
