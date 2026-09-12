{-# LANGUAGE OverloadedStrings #-}

{- | End-to-end spec for the full Telegram Stars purchase loop through the
headless @tgTest@ runner.

One journey drives the demo application (real PostgreSQL; Telegram/AI/mail
mocked by the test performer) through @/topup@ → invoice ('OutSendInvoice') →
pre-checkout approval ('OutAnswerPreCheckoutQuery') → @successful_payment@ →
credit confirmation, synchronized ONLY through the DSL's STM @waitFor*@ ops
(the headless dispatch is fire-and-forget). After the @tgTest@ block completes
(mailbox drained), the @stars_payments@ ledger is checked over an independent
'TestDbSupport.openTestConn' connection: exactly one row for the journey's
charge id. Finally the SAME successful-payment update is redelivered through a
second headless run: the row count must stay at one and the bot must not crash
(an action crash preempts the bounded wait as 'TgTestError.TgTestActionError',
so the expected outcome is precisely 'TgTestError.TgTestTimeout').

The shared test database is never truncated between specs, so the invoice
payload and charge id are namespaced for this spec only.
-}
module StarsTgTestSpec (spec) where

import RIO
import Test.Hspec

import BotHandler (BotHandlerConfig (..), runUpdate)
import ChatStateStore (newChatStateStore)
import Common
    ( StarsPayment
    , starsPaymentCurrencyAmount
    , starsPaymentInvoicePayload
    , starsPaymentStars
    , starsPaymentTelegramPaymentChargeId
    , starsPaymentUserId
    )
import Database.PostgreSQL.Simple (Only (..), close, query)
import Database.PostgreSQL.Simple.Types (Query (..))
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Telegram.Stars (StarsPackage (..))
import LazyCircus.Testing.Performer
    ( Mocks
    , OutgoingKind (..)
    , OutgoingMessage (..)
    , TestConfig
    , runScenarioProgram
    , runWithConfig
    )
import LazyCircus.Testing.TgTest
    ( Mailboxes
    , TgTestError (..)
    , TelegramTestScript
    , defaultTgTestConfig
    , guardWith
    , sendMessage
    , sendPreCheckoutQueryByUser
    , sendSuccessfulPaymentByUser
    , tgTest
    , waitForMatching
    , waitForReply
    , withTimeout
    )
import LazyCircus.Testing.Updates (defaultTestChatId, defaultTestUserId)
import PollRegistry (newPollRegistry)
import SimpleServiceLib (AllServices)
import Telegram.Bot.API (Update)
import TestDbSupport (openTestConn)
import TestHelpers.Bot (withBotTestApp)

-- | The single Stars package sold by the handler in this spec.
-- The test database is shared and never truncated, so 'starsPackagePayload'
-- (stored into @stars_payments.invoice_payload@) is namespaced for this spec.
specPkg :: StarsPackage
specPkg =
    StarsPackage
        { starsPackageTitle = "Circus Ticket"
        , starsPackageDescription = "One admission to the big top"
        , starsPackagePayload = "ticket-stars-tgtest-e2e"
        , starsPackageStars = 150
        , starsPackageCurrencyAmount = 199
        }

-- | Pre-checkout query id used by this spec's journey (unique per spec, like
-- 'specChargeId').
specQueryId :: Text
specQueryId = "pcq-stars-tgtest-e2e"

-- | Telegram charge id for this spec's journey — the @stars_payments@
-- idempotency key; unique per spec since rows leak across specs in the shared
-- test database.
specChargeId :: Text
specChargeId = "charge-stars-tgtest-e2e"

-- | The full purchase journey: @/topup@ → invoice → pre-checkout approval →
-- successful payment → credit confirmation. Each step is synchronized through
-- the mailbox via STM (never sleeps); the send order defines the
-- invoice → approve → pay order.
purchasePilot :: TelegramTestScript ()
purchasePilot = do
    _ <- sendMessage ("/topup " <> starsPackagePayload specPkg)
    invoice <- waitForMatching isTopupInvoice "the /topup invoice"
    guardWith "expected the invoice in the default test chat"
        (omChatId invoice == Just defaultTestChatId)
    guardWith "expected the invoice to advertise the configured package title"
        (omText invoice == Just (starsPackageTitle specPkg))

    _ <- sendPreCheckoutQueryByUser
        defaultTestUserId
        specQueryId
        (starsPackagePayload specPkg)
        (fromIntegral (starsPackageStars specPkg))
    answer <- waitForMatching isPreCheckoutAnswer "the pre-checkout approval"
    guardWith "expected the approval to answer OUR pre-checkout query id"
        (omText answer == Just specQueryId)

    _ <- sendSuccessfulPaymentByUser
        defaultTestUserId
        defaultTestChatId
        specChargeId
        (starsPackagePayload specPkg)
        (fromIntegral (starsPackageStars specPkg))
    reply <- waitForReply
    guardWith "expected the credit confirmation" (reply == expectedCreditText)
  where
    -- | The bot's Stars invoice for the default test chat.
    isTopupInvoice om = omKind om == OutSendInvoice && omChatId om == Just defaultTestChatId

    -- | The bot's pre-checkout approval; the capture carries the answered query id.
    isPreCheckoutAnswer om = omKind om == OutAnswerPreCheckoutQuery && omText om == Just specQueryId

-- | Redelivery of the exact same successful-payment update through a fresh
-- headless run. The duplicate charge id must be ignored: no second
-- confirmation may arrive and the bot action must not crash. Both properties
-- are observed through one bounded wait — an action crash preempts the
-- timeout as 'TgTestActionError' (the error channel is checked before the
-- timer inside 'waitForMatching'), so the expected outcome is precisely
-- 'TgTestTimeout'.
redeliveryPilot :: TelegramTestScript ()
redeliveryPilot = do
    _ <- sendSuccessfulPaymentByUser
        defaultTestUserId
        defaultTestChatId
        specChargeId
        (starsPackagePayload specPkg)
        (fromIntegral (starsPackageStars specPkg))
    withTimeout 500000 (void waitForReply)

-- | Run a DSL script via 'tgTest' against the demo app selling 'specPkg'.
runStarsTgTest :: DefaultApp AllServices -> TelegramTestScript a -> IO (Mailboxes, Either TgTestError a)
runStarsTgTest app = tgTest defaultTgTestConfig (buildStarsDemoAction app [specPkg])

-- | The Stars purchase journey, end to end through the headless @tgTest@
-- runner: green path (invoice → pre-checkout approval → payment → credit →
-- exactly one ledger row) followed by the idempotency redelivery (same
-- successful-payment update → no second confirmation, no crash, still one row).
spec :: Spec
spec = aroundAll withBotTestApp $
    describe "tgTest: Stars purchase loop E2E" $
        it "walks /topup → invoice → pre-checkout approval → payment → credit, persists exactly one ledger row, and ignores a redelivered charge id" $ \app -> do
            -- The journey: full purchase loop through the headless runner.
            (_mailboxes, result) <- runStarsTgTest app purchasePilot
            case result of
                Left e -> expectationFailure ("expected the purchase loop to complete, but it aborted: " ++ show e)
                Right () -> pure ()

            -- Direct DB check after the tgTest block completed (mailbox drained):
            -- exactly one credited row for the journey's charge id.
            rows <- queryStarsPaymentsByChargeId specChargeId
            case rows of
                [row] -> do
                    starsPaymentTelegramPaymentChargeId row `shouldBe` specChargeId
                    starsPaymentUserId row `shouldBe` Just 1001 -- defaultTestUserId = UserId 1001
                    starsPaymentStars row `shouldBe` Just (fromIntegral (starsPackageStars specPkg))
                    starsPaymentCurrencyAmount row
                        `shouldBe` Just (fromIntegral (starsPackageCurrencyAmount specPkg))
                    starsPaymentInvoicePayload row `shouldBe` Just (starsPackagePayload specPkg)
                _ -> expectationFailure ("expected exactly one stars_payments row for the charge id, got: " ++ show (length rows))

            -- Idempotency at the E2E level: the SAME successful-payment update
            -- redelivered writes nothing and does not crash the bot.
            (_redeliveryMailboxes, redelivery) <- runStarsTgTest app redeliveryPilot
            case redelivery of
                Left (TgTestTimeout _) -> pure ()
                Left e ->
                    expectationFailure
                        ("expected a quiet timeout after redelivery (no duplicate confirmation, no crash), got: " ++ show e)
                Right () ->
                    expectationFailure "expected no reply after the redelivered payment, but the bot sent one"

            rowsAfterRedelivery <- queryStarsPaymentsByChargeId specChargeId
            length rowsAfterRedelivery `shouldBe` 1

-- | Build the demo bot's @'Update' -> 'IO' ()@ action under the test performer,
-- selling the given Stars packages. Mirrors @TestHelpers.Bot.buildDemoAction@:
-- the bot runs its ordinary driver ('BotHandler.runUpdate'); only the performer
-- is the test performer, so every Telegram side effect is mocked and captured
-- in the shared mailbox. The shared helper's handler config sells no Stars
-- packages, so the @/topup@ journey uses this local override (same pattern as
-- @StarsFlowSpec@'s local handler config); every call gets a FRESH
-- 'ChatStateStore' and 'PollRegistry'.
-- PRE-CONTRACT: The 'DefaultApp' has the @demo-bot@ registered.
-- POST-CONTRACT: The returned action is safe to run concurrently (the runner
-- dispatches updates fire-and-forget).
buildStarsDemoAction ::
    DefaultApp AllServices ->
    [StarsPackage] ->
    TestConfig app ->
    Mocks AllServices ->
    IO (Update -> IO ())
buildStarsDemoAction app packages cfg mocks = do
    store <- newChatStateStore
    pollRegistry <- newPollRegistry
    pure $
        runUpdate
            (runWithConfig app cfg mocks . runScenarioProgram)
            BotHandlerConfig
                { bhcBotName = "demo-bot"
                , bhcNotificationEmail = Nothing
                , bhcPollRegistry = pollRegistry
                , bhcStarsPackages = packages
                }
            store

-- | Exact confirmation text the handler sends on first credit (mirrors
-- @StarsScenarios.creditText@ for 'specPkg').
expectedCreditText :: Text
expectedCreditText =
    "✅ Top-up credited: "
        <> starsPackageTitle specPkg
        <> " — "
        <> tshow (starsPackageStars specPkg)
        <> " ⭐️. Thank you for supporting the circus!"

-- | Read the @stars_payments@ ledger rows matching 'specChargeId' over an
-- independent connection to the fixture database. The column name is a fixed
-- call-site literal, never external input.
-- PRE-CONTRACT: Must be called inside the @TestHelpers.Bot.withBotTestApp@
-- fixture (the @lazy_circus_test@ database exists and is migrated).
-- POST-CONTRACT: Returns exactly the rows whose @telegram_payment_charge_id@
-- equals 'specChargeId', ordered by id; the connection is closed before return.
queryStarsPaymentsByChargeId :: Text -> IO [StarsPayment]
queryStarsPaymentsByChargeId chargeId =
    bracket openTestConn close $ \conn ->
        query
            conn
            ( Query
                ( encodeUtf8
                    ( "SELECT id, telegram_payment_charge_id, user_id, stars, currency_amount, invoice_payload, created_at"
                        <> " FROM stars_payments WHERE telegram_payment_charge_id = ? ORDER BY id"
                    )
                )
            )
            (Only chargeId)
