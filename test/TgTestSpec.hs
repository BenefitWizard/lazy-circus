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
    , sendFile
    , waitForReply
    )
import SimpleServiceLib (AllServices)
import Telegram.Bot.API.GettingUpdates (UpdateId (..))
import Telegram.Bot.API.Types (FileId (..), MessageId (..))
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

-- | Surfaces the @(UpdateId, MessageId)@ pair returned by 'sendMessage' after a
-- single @/start@ turn. The welcome reply is drained so the run quiesces
-- cleanly; the pair itself is the value under test (the factory invariant sets
-- @message_id == update_id@ on the sent user message).
messageIdPilot :: TelegramTestScript (UpdateId, MessageId)
messageIdPilot = do
    pair <- sendMessage "/start"
    _ <- waitForReply
    pure pair

-- | Surfaces the 'MessageId' returned by 'sendFile' after a single document
-- upload. The demo bot treats a bare file as a no-op (its 'messageText' is
-- 'Nothing'), so it produces no reply and no 'waitForReply' is needed; the run
-- quiesces cleanly once the no-op dispatch settles.
fileMessageIdPilot :: TelegramTestScript MessageId
fileMessageIdPilot = do
    (_uid, mid) <- sendFile (FileId "test-file")
    pure mid

-- | Surfaces the 'MessageId's of two successive 'sendMessage' calls so a test
-- can assert the factory's update counter is monotonic. Each welcome reply is
-- drained so the run quiesces cleanly between sends.
increasingMessageIdPilot :: TelegramTestScript (MessageId, MessageId)
increasingMessageIdPilot = do
    (_, m1) <- sendMessage "/start"
    _ <- waitForReply
    (_, m2) <- sendMessage "/start"
    _ <- waitForReply
    pure (m1, m2)

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

    describe "tgTest: sendMessage / sendFile return-type (UpdateId, MessageId)" $ do
        it "sendMessage returns a MessageId equal in value to the returned UpdateId" $ \app -> do
            (_mailboxes, result) <- runTgTest app messageIdPilot
            case result of
                Left e ->
                    expectationFailure ("expected the turn to complete, but it aborted: " ++ show e)
                Right (uid, mid) -> do
                    let UpdateId u = uid
                        MessageId n = mid
                    n `shouldBe` fromIntegral u
                    n `shouldSatisfy` (> 0)

        it "sendFile returns a positive MessageId" $ \app -> do
            (_mailboxes, result) <- runTgTest app fileMessageIdPilot
            case result of
                Left e ->
                    expectationFailure ("expected the run to complete, but it aborted: " ++ show e)
                Right (MessageId n) ->
                    n `shouldSatisfy` (> 0)

        it "two successive sendMessage calls return strictly increasing MessageIds" $ \app -> do
            (_mailboxes, result) <- runTgTest app increasingMessageIdPilot
            case result of
                Left e ->
                    expectationFailure ("expected the dialog to complete, but it aborted: " ++ show e)
                Right (MessageId n1, MessageId n2) -> do
                    n2 `shouldSatisfy` (> n1)
                    n1 `shouldSatisfy` (> 0)
