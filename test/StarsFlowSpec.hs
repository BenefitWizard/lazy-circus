{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Handler-level end-to-end coverage of the demo Telegram Stars top-up loop.
--
-- Every example drives the bot's ordinary update driver ('BotHandler.runUpdate')
-- under the test performer: Telegram, AI and mail are mocked (outgoing traffic
-- lands in the STM mailbox drained via 'readOutgoingMailbox') while the database
-- stays REAL — @stars_payments@ ledger rows are read back over an independent
-- connection ('TestDbSupport.openTestConn').
--
-- Rows leak between examples inside one fixture (the test database is created
-- once per 'TestHelpers.Bot.withBotTestApp' and never truncated), so every
-- example namespaces its charge ids and invoice payloads ('mkTestPackage') and
-- asserts only on its own rows.
module StarsFlowSpec (spec) where

import RIO
import RIO.Text qualified as Text
import Test.Hspec

import BotApp (ChatState (..), Model (..))
import BotHandler (BotHandlerConfig (..), runUpdate)
import ChatStateStore (ChatStateStore, newChatStateStore, withChatState)
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
import LazyCircus.App.Log (AppLogMsg (..))
import LazyCircus.Telegram.Stars (StarsPackage (..))
import LazyCircus.Testing.Performer
    ( Mocks
    , OutgoingKind (..)
    , OutgoingMessage (..)
    , defaultTestConfig
    , makeMocks
    , readLog
    , readOutgoingMailbox
    , runScenarioProgram
    , runWithConfig
    )
import LazyCircus.Testing.Updates
    ( defaultTestChatId
    , defaultTestUserId
    , mkPreCheckoutQueryUpdateByUser
    , mkSuccessfulPaymentUpdateByUser
    , mkTextUpdateIn
    , newUpdateFactory
    )
import PollRegistry (PollRegistry, newPollRegistry)
import SimpleServiceLib (AllServices)
import Telegram.Bot.API (Update)
import TestDbSupport (openTestConn)
import TestHelpers.Bot (withBotTestApp)

spec :: Spec
spec = aroundAll withBotTestApp $ do
    describe "preCheckout" $
        it "answers a pre_checkout_query with exactly one OutAnswerPreCheckoutQuery and never touches the chat Model" $ \app -> do
            mocks <- makeMocks
            (driver, store) <- mkStarsDriver app [mkTestPackage "precheckout"] mocks
            updateFactory <- newUpdateFactory

            -- Give chat 1 a non-initial FSM state so untouchedness is observable.
            newactCmd <- mkTextUpdateIn updateFactory defaultTestChatId "/newact"
            driver newactCmd
            void $ readOutgoingMailbox mocks -- drain the name prompt

            -- The pre_checkout_query branch sits BEFORE runUpdate's chat-id
            -- gate (like poll_answer): the update is chat-less and must not
            -- queue behind any chat's withChatState lock.
            checkout <- mkPreCheckoutQueryUpdateByUser
                updateFactory
                defaultTestUserId
                "pcq-starsflow-precheckout"
                (starsPackagePayload (mkTestPackage "precheckout"))
                150
            driver checkout

            captures <- readOutgoingMailbox mocks
            map omKind captures `shouldBe` [OutAnswerPreCheckoutQuery]
            answer <- capturedOfKind OutAnswerPreCheckoutQuery captures
            omText answer `shouldBe` Just "pcq-starsflow-precheckout"
            -- a pre-checkout answer targets a query, not a chat
            omChatId answer `shouldBe` Nothing

            -- The pre-checkout branch bypassed withChatState: the store still
            -- holds the WaitingForName state the /newact command left behind.
            storedState <- withChatState store defaultTestChatId (\m -> pure (m, modelChatState m))
            storedState `shouldBe` WaitingForName

    describe "successfulPayment" $ do
        it "credits one stars_payments row for the charge id and sends exactly one confirmation reply" $ \app -> do
            let ns = "credited"
                pkg = mkTestPackage ns
            mocks <- makeMocks
            (driver, _) <- mkStarsDriver app [pkg] mocks
            updateFactory <- newUpdateFactory
            payment <- mkSuccessfulPaymentUpdateByUser
                updateFactory
                defaultTestUserId
                defaultTestChatId
                (chargeIdFor ns)
                (starsPackagePayload pkg)
                150
            driver payment

            -- The confirmation is counted after the credit settled: the
            -- driver runs handleScenario synchronously, so the post-hoc
            -- mailbox drain sees the fully settled turn.
            captures <- readOutgoingMailbox mocks
            map omKind captures `shouldBe` [OutSendMessage]
            reply <- capturedOfKind OutSendMessage captures
            omChatId reply `shouldBe` Just defaultTestChatId
            omText reply `shouldBe` Just (expectedCreditText pkg)

            rows <- queryStarsPaymentsByChargeId (chargeIdFor ns)
            length rows `shouldBe` 1
            case rows of
                [row] -> do
                    starsPaymentTelegramPaymentChargeId row `shouldBe` chargeIdFor ns
                    starsPaymentUserId row `shouldBe` Just 1001 -- defaultTestUserId = UserId 1001
                    starsPaymentStars row `shouldBe` Just 150
                    starsPaymentCurrencyAmount row `shouldBe` Just 199
                    starsPaymentInvoicePayload row `shouldBe` Just (starsPackagePayload pkg)
                _ -> pure () -- unreachable after the length assertion

        it "ignores a redelivered charge id: still one row, no second confirmation, duplicate logged" $ \app -> do
            let ns = "duplicate"
                pkg = mkTestPackage ns
            mocks <- makeMocks
            (driver, _) <- mkStarsDriver app [pkg] mocks
            updateFactory <- newUpdateFactory
            payment <- mkSuccessfulPaymentUpdateByUser
                updateFactory
                defaultTestUserId
                defaultTestChatId
                (chargeIdFor ns)
                (starsPackagePayload pkg)
                150

            driver payment -- first delivery credits and confirms
            void $ readOutgoingMailbox mocks -- drain the first confirmation

            driver payment -- SAME update redelivered

            captures <- readOutgoingMailbox mocks
            captures `shouldSatisfy` null -- no second confirmation

            rows <- queryStarsPaymentsByChargeId (chargeIdFor ns)
            length rows `shouldBe` 1

            logs <- readLog mocks
            any (isLogContaining "stars payment credited") logs `shouldBe` True
            any (isLogContaining "duplicate stars payment delivery ignored") logs `shouldBe` True

    describe "topup" $ do
        it "sends an OutSendInvoice with the configured title for a known payload, whose payload round-trips to a credit" $ \app -> do
            let ns = "invoice"
                pkg = mkTestPackage ns
            mocks <- makeMocks
            (driver, _) <- mkStarsDriver app [pkg] mocks
            updateFactory <- newUpdateFactory
            topupCmd <- mkTextUpdateIn updateFactory defaultTestChatId ("/topup " <> starsPackagePayload pkg)
            driver topupCmd

            captures <- readOutgoingMailbox mocks
            map omKind captures `shouldBe` [OutSendInvoice]
            invoice <- capturedOfKind OutSendInvoice captures
            omChatId invoice `shouldBe` Just defaultTestChatId
            -- The mailbox capture carries the invoice TITLE; the payload is
            -- not part of the capture, so it is proven by the loop closing
            -- below: a payment echoing it must credit the configured package.
            omText invoice `shouldBe` Just (starsPackageTitle pkg)

            payment <- mkSuccessfulPaymentUpdateByUser
                updateFactory
                defaultTestUserId
                defaultTestChatId
                (chargeIdFor ns)
                (starsPackagePayload pkg)
                150
            driver payment
            confirmations <- readOutgoingMailbox mocks
            map omKind confirmations `shouldBe` [OutSendMessage]
            reply <- capturedOfKind OutSendMessage confirmations
            omText reply `shouldBe` Just (expectedCreditText pkg)

        it "replies with only the hint for an unknown payload, with no invoice and no DB write" $ \app -> do
            let ns = "unknown"
                pkg = mkTestPackage ns
                unknownPayload = "no-such-package-" <> ns
            mocks <- makeMocks
            (driver, _) <- mkStarsDriver app [pkg] mocks
            updateFactory <- newUpdateFactory
            topupCmd <- mkTextUpdateIn updateFactory defaultTestChatId ("/topup " <> unknownPayload)
            driver topupCmd

            captures <- readOutgoingMailbox mocks
            map omKind captures `shouldBe` [OutSendMessage]
            reply <- capturedOfKind OutSendMessage captures
            omChatId reply `shouldBe` Just defaultTestChatId
            omText reply `shouldBe` Just (expectedTopupHint pkg)

            rows <- queryStarsPaymentsByPayload unknownPayload
            rows `shouldBe` []

-- | Bot handler config pointing at the @demo-bot@ registered by the shared
-- 'TestHelpers.Bot.withBotTestApp' fixture, selling the given Stars packages
-- (the fixture's own 'TestHelpers.Bot.demoHandlerConfig' sells none).
-- PRE-CONTRACT: None.
-- POST-CONTRACT: The config routes every @tgScript@ effect to @demo-bot@.
starsHandlerConfig :: [StarsPackage] -> PollRegistry -> BotHandlerConfig
starsHandlerConfig packages pollRegistry = BotHandlerConfig
    { bhcBotName = "demo-bot"
    , bhcNotificationEmail = Nothing
    , bhcPollRegistry = pollRegistry
    , bhcStarsPackages = packages
    }

-- | Stars package sold by the handler in these examples.
-- The shared fixture's database is never truncated between examples, so
-- 'starsPackagePayload' (stored into @stars_payments.invoice_payload@) must be
-- unique per example.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Two calls with distinct namespaces never share a payload.
mkTestPackage :: Text -> StarsPackage
mkTestPackage ns =
    StarsPackage
        { starsPackageTitle = "Circus Ticket"
        , starsPackageDescription = "One admission to the big top"
        , starsPackagePayload = "ticket-" <> ns
        , starsPackageStars = 150
        , starsPackageCurrencyAmount = 199
        }

-- | Telegram charge id for an example namespace, unique per example like
-- 'mkTestPackage' (it is the @stars_payments@ idempotency key).
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Two calls with distinct namespaces never share a charge id.
chargeIdFor :: Text -> Text
chargeIdFor ns = "charge-" <> ns

-- | Build the bot's @'Update' -> 'IO' ()@ driver ('BotHandler.runUpdate') under
-- the test performer, with the given Stars packages configured. Mirrors the
-- @runUpdate@ wiring of @BotHandlerSpec@'s runUpdate examples.
-- PRE-CONTRACT: The 'DefaultApp' has the @demo-bot@ registered; 'mocks' was
-- created by 'makeMocks' and is also used to read back captures.
-- POST-CONTRACT: Returns the driver together with the 'ChatStateStore' it
-- serialises chat state on (exposed so examples can assert chat-model
-- untouchedness); each call gets a fresh store and 'PollRegistry'.
mkStarsDriver :: DefaultApp AllServices -> [StarsPackage] -> Mocks AllServices -> IO (Update -> IO (), ChatStateStore)
mkStarsDriver app packages mocks = do
    store <- newChatStateStore
    pollRegistry <- newPollRegistry
    let -- | One bot turn under the test performer.
        driver =
            runUpdate
                (runWithConfig app (defaultTestConfig @()) mocks . runScenarioProgram)
                (starsHandlerConfig packages pollRegistry)
                store
    pure (driver, store)

-- | Read the @stars_payments@ ledger rows matching one charge id, ordered by id.
-- PRE-CONTRACT: Must be called inside the 'TestHelpers.Bot.withBotTestApp'
-- fixture (the @lazy_circus_test@ database exists and the app's pool is alive).
-- POST-CONTRACT: Returns exactly the rows whose @telegram_payment_charge_id@
-- equals the given id (empty when none).
queryStarsPaymentsByChargeId :: Text -> IO [StarsPayment]
queryStarsPaymentsByChargeId = queryStarsPayments "telegram_payment_charge_id"

-- | 'queryStarsPaymentsByChargeId' keyed by invoice payload instead.
-- PRE-CONTRACT: Same as 'queryStarsPaymentsByChargeId'.
-- POST-CONTRACT: Returns exactly the rows whose @invoice_payload@ equals the
-- given payload (empty when none).
queryStarsPaymentsByPayload :: Text -> IO [StarsPayment]
queryStarsPaymentsByPayload = queryStarsPayments "invoice_payload"

-- | Read @stars_payments@ rows matching one column value over an independent
-- connection to the fixture database. The column name is a fixed call-site
-- literal at both use sites, never external input.
-- PRE-CONTRACT: The database exists (see 'queryStarsPaymentsByChargeId').
-- POST-CONTRACT: Returns the matching rows ordered by id; the connection is
-- closed before return.
queryStarsPayments :: Text -> Text -> IO [StarsPayment]
queryStarsPayments column value =
    bracket openTestConn close $ \conn ->
        query
            conn
            ( Query
                ( encodeUtf8
                    ( "SELECT id, telegram_payment_charge_id, user_id, stars, currency_amount, invoice_payload, created_at"
                        <> " FROM stars_payments WHERE "
                        <> column
                        <> " = ? ORDER BY id"
                    )
                )
            )
            (Only value)

-- | Extract the single capture of the given kind from drained mailbox traffic.
-- PRE-CONTRACT: The captures come from a step that produced at most one message
-- of the kind.
-- POST-CONTRACT: Fails the example unless exactly one capture of that kind is
-- present; the fallback value is unreachable after 'expectationFailure'.
capturedOfKind :: OutgoingKind -> [OutgoingMessage] -> IO OutgoingMessage
capturedOfKind kind captures = case filter ((== kind) . omKind) captures of
    [capture] -> pure capture
    _ -> do
        expectationFailure ("Expected exactly one " <> show kind <> " capture, got: " <> show captures)
        pure (OutgoingMessage kind Nothing Nothing Nothing Nothing)

-- | Confirmation text the handler sends on first credit, for the configured
-- package (mirrors @StarsScenarios.creditText@).
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Result is the exact @sendMessage@ text of the credit reply.
expectedCreditText :: StarsPackage -> Text
expectedCreditText pkg =
    "✅ Top-up credited: "
        <> starsPackageTitle pkg
        <> " — "
        <> tshow (starsPackageStars pkg)
        <> " ⭐️. Thank you for supporting the circus!"

-- | Exact hint text the handler replies for @/topup@ with an unknown payload
-- (mirrors @BotHandler.topupHintText@ with the single configured package).
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Result is the exact @sendMessage@ text of the hint reply.
expectedTopupHint :: StarsPackage -> Text
expectedTopupHint pkg =
    "❓ Unknown top-up package. ⭐️ Top-up packages:\n"
        <> "• /topup "
        <> starsPackagePayload pkg
        <> " — "
        <> tshow (starsPackageStars pkg)
        <> " ⭐️ (XTR)\n"
        <> "Send /topup <payload> to get an invoice."

-- | Check whether a log message contains the given substring.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Returns True when any 'AppLogMsg' variant contains the text.
isLogContaining :: Text -> AppLogMsg -> Bool
isLogContaining target = \case
    AppLogMsg t       -> target `Text.isInfixOf` t
    SensitiveLogMsg t -> target `Text.isInfixOf` t
    ErrorLogMsg t     -> target `Text.isInfixOf` t
    WarnLogMsg t      -> target `Text.isInfixOf` t
