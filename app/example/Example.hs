{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import RIO hiding (try, SomeException)
import Control.Exception (SomeException, try)
import System.IO (putStrLn)

import DemoEnv
import Example.DemoScenarios

import LazyCircus.App.Default (DefaultApp)
import SimpleServiceLib (AllServices)
import LazyCircus.Scenario (ScenarioProgram)
import LazyCircus.Script (Script)

-- | Entry point: read configuration, set up the demo app, run scenarios.
main :: IO ()
main = do
    config <- readDemoConfig
    putStrLn "🎪 Lazy Circus Demo (Production Mode)"
    putStrLn "======================================"

    printConfigStatus config

    withDemoApp config $ \app -> do
        putStrLn "\n🚀 Running scenarios...\n"

        runAndPrint app "1. DB CRUD"          dbCrudScenario
        runAndPrint app "2. DB Advanced"       dbAdvancedScenario

        when (hasTelegram config) $
            runAndPrint app "3. Telegram"      (telegramScenario (cfgTgChatId config))

        runAndPrint app "4. Mail"              mailScenario

        when (hasAI config) $
            runAndPrint app "5. AI"            aiScenario

        runAndPrint app "6. Logging"           loggingScenario
        runAndPrint app "7. Orchestration"     orchestrationScenario
        runAndPrint app "8. Full Lifecycle"    fullCircusLifecycleScenario

        putStrLn "\n✅ All scenarios completed!"

-- | Print which services are available based on the configuration.
printConfigStatus :: DemoConfig -> IO ()
printConfigStatus config = do
    putStrLn $ "  PostgreSQL:  localhost:5432 (docker)"
    putStrLn $ "  Telegram:    " ++ if hasTelegram config then "✅ token set" else "❌ TG_TOKEN not set"
    putStrLn $ "  AI:          " ++ if hasAI config then "✅ API key set" else "❌ AI_API_KEY not set"
    putStrLn $ "  SMTP:        " ++ cfgSmtpHost config ++ ":" ++ show (cfgSmtpPort config)

-- | Run a single scenario and print its result.
runAndPrint :: DefaultApp AllServices -> String -> ScenarioProgram Script AllServices () -> IO ()
runAndPrint app label scenario = do
    putStrLn $ "\n🎭 " ++ label
    putStrLn $ replicate (4 + length label) '-'
    result <- try $ runDemoScenario app scenario
    case result of
        Left (e :: SomeException) ->
            putStrLn $ "  ❌ Error: " ++ show e
        Right _ ->
            putStrLn "  ✅ OK"

-- | Check if Telegram is configured.
hasTelegram :: DemoConfig -> Bool
hasTelegram config = isJust (cfgTgToken config) && isJust (cfgTgChatId config)

-- | Check if AI is configured.
hasAI :: DemoConfig -> Bool
hasAI config = isJust (cfgAiApiKey config)
