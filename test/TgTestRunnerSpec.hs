{-# LANGUAGE OverloadedStrings #-}

{- | T9 completion spec: the 'LazyCircus.Testing.TgTest' runner's timeout path.

Negative-control case: a @waitFor*@ that has no forthcoming reply aborts the DSL
with a 'TgTestTimeout'. The first @/start@ reply is consumed under the default
generous timeout; only the second (waiting for a reply that never arrives) is
wrapped in a short 'withTimeout' so the example stays fast.
-}
module TgTestRunnerSpec (spec) where

import RIO
import Test.Hspec

import LazyCircus.Testing.TgTest
    ( TgTestError (..)
    , TelegramTestScript
    , sendMessage
    , waitForReply
    , withTimeout
    )
import TestHelpers.Bot (runDemoTgTest, withBotTestApp)

spec :: Spec
spec = aroundAll withBotTestApp $ do
    describe "tgTest: timeout path" $ do
        it "a waitFor* with no forthcoming reply aborts with a TgTestTimeout" $ \app -> do
            (_mailboxes, result) <-
                runDemoTgTest app $ do
                    _ <- sendMessage "/start"
                    _ <- waitForReply
                    withTimeout 200000 waitForReply
            case result of
                Left (TgTestTimeout _) -> pure ()
                Left e -> expectationFailure ("expected TgTestTimeout, got: " ++ show e)
                Right _ -> expectationFailure "expected a timeout but the dialog completed"
