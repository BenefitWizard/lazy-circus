{-# LANGUAGE OverloadedStrings #-}

{- | Pilot end-to-end spec for the 'LazyCircus.Testing.TgTest' runner.

Drives the full @/newact@ dialog (the plan's pilot scenario) through the headless
runner against the real demo application (real PostgreSQL; AI mocked to no
response by the test performer). Asserts both the green path (the dialog
completes) and the red path (a deliberate 'guard' mismatch aborts with 'Left').
-}
module TgTestSpec (spec) where

import RIO
import RIO.Text qualified as Text
import Test.Hspec

import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Testing.TgTest
    ( Mailboxes
    , TgTestError
    , TelegramTestScript
    , guardWith
    , sendMessage
    , waitForReply
    )
import SimpleServiceLib (AllServices)
import TestHelpers.Bot (runDemoTgTest, withBotTestApp)

-- | The plan's pilot: the full @/newact@ dialog.
newactPilot :: TelegramTestScript ()
newactPilot = do
    _ <- sendMessage "/newact"
    r1 <- waitForReply
    guardWith "expected the act-name prompt" (r1 == "🎭 Enter act name:")
    _ <- sendMessage "Fire Juggling"
    r2 <- waitForReply
    guardWith "expected the act-description prompt" (r2 == "📝 Enter act description:")
    _ <- sendMessage "Breathes fire"
    -- The description turn emits a progress reply ("⏳ Creating act...")
    -- followed by the formatted act; read both.
    progress <- waitForReply
    guardWith "expected the creating-act progress reply" (progress == "⏳ Creating act...")
    r3 <- waitForReply
    guardWith "expected the formatted act to contain its name" ("Fire Juggling" `Text.isInfixOf` r3)

-- | A negative pilot: asserts a deliberately-wrong reply, which must abort with 'Left'.
negativePilot :: TelegramTestScript ()
negativePilot = do
    _ <- sendMessage "/start"
    r1 <- waitForReply
    guardWith "deliberately wrong expectation" (r1 == "this text is never sent")

-- | T9 trivial smoke: a single /start turn whose reply is the welcome text.
startPilot :: TelegramTestScript Text
startPilot = do
    _ <- sendMessage "/start"
    waitForReply

runTgTest :: DefaultApp AllServices -> TelegramTestScript a -> IO (Mailboxes, Either TgTestError a)
runTgTest = runDemoTgTest

spec :: Spec
spec = aroundAll withBotTestApp $ do
    describe "tgTest: /newact pilot" $ do
        it "completes the full /newact dialog end-to-end" $ \app -> do
            (_mailboxes, result) <- runTgTest app newactPilot
            case result of
                Left e -> expectationFailure ("expected the dialog to complete, but it aborted: " ++ show e)
                Right _ -> pure ()

        it "aborts with Left when a guard does not hold" $ \app -> do
            (_mailboxes, result) <- runTgTest app negativePilot
            result `shouldSatisfy` isLeft

    describe "tgTest: /start smoke (T9)" $ do
        it "returns the welcome text from a single /start turn" $ \app -> do
            (_mailboxes, result) <- runTgTest app startPilot
            case result of
                Left e -> expectationFailure ("expected a welcome reply, but it aborted: " ++ show e)
                Right reply ->
                    reply `shouldSatisfy` ("🎪 Welcome to Lazy Circus Bot!" `Text.isPrefixOf`)
