{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Telegram Stars (XTR) top-up loop scenarios built on Lazy Circus: sending
the Stars invoice, auto-approving the pre-checkout query, and idempotently
crediting the completed payment into the @stars_payments@ ledger.
-}
module StarsScenarios (
    -- * Entry points
    handlePreCheckout,
    creditStarsPayment,
    topUpInvoice,

    -- * Credit outcomes
    CreditedStatus (..),
    ) where

import RIO hiding (log, logError, logInfo, logWarn)
import RIO.Time (UTCTime)

import Common hiding (migration)
import Data.Foldable qualified as Foldable
import Database.Beam
import Database.Beam.Backend.SQL.BeamExtensions
    ( BeamHasInsertOnConflict (..)
    , runInsertReturningList
    )
import LazyCircus (dbScript, tgScript)
import LazyCircus.Scenario
    ( DbMode (..)
    , ScenarioProgram
    , evalScript
    , getDateTime
    , logError
    , logInfo
    , logWarn
    , runSafely
    , withLogContext
    )
import LazyCircus.Scenario (withLogEntry)
import LazyCircus.Scene.DB.Lang (DBScript, runQuery)
import LazyCircus.Scene.Telegram qualified as Tg
import LazyCircus.Script (Script)
import LazyCircus.Telegram.Stars
    ( StarsPackage (..)
    , mkPreCheckoutApproval
    , mkStarsInvoiceRequest
    )
import Telegram.Bot.API
    ( ChatId
    , PreCheckoutQuery
    , SomeChatId (..)
    , SuccessfulPayment
    , UserId (..)
    , defSendMessage
    , preCheckoutQueryId
    , successfulPaymentInvoicePayload
    , successfulPaymentTelegramPaymentChargeId
    , successfulPaymentTotalAmount
    )

-- | Outcome of crediting a Telegram Stars payment into the ledger.
data CreditedStatus
    = CreditedNow StarsPayment -- ^ first delivery of this charge id; the newly inserted ledger row is returned
    | DuplicateCharge          -- ^ this charge id was already credited; nothing was written
    | UnknownPayload           -- ^ the invoice payload matched no package; nothing was written
    deriving (Show, Eq)

{- | Auto-approve a Telegram Stars pre-checkout query.
PRE-CONTRACT: @query@ must be a currently open pre-checkout query delivered
  for the bot named by @botName@; the answer must reach Telegram within 10
  seconds of the query or the payment times out.
POST-CONTRACT: The query is always answered with @ok = True@; no price or
  payload validation happens here — crediting is validated idempotently by
  'creditStarsPayment' on the subsequent @successful_payment@ update.
-}
handlePreCheckout :: Text -> PreCheckoutQuery -> ScenarioProgram Script serviceLib ()
handlePreCheckout botName query =
    withLogEntry "query_id" (preCheckoutQueryId query) $ do
        logInfo "stars pre-checkout approved"
        evalScript $
            tgScript botName $
                Tg.answerPreCheckoutQuery (mkPreCheckoutApproval (preCheckoutQueryId query))

{- | Send a Telegram Stars (XTR) invoice for the given package to the chat.
PRE-CONTRACT: The bot named by @botName@ is registered in the app's
  @botEnvs@; the 'StarsPackage' fields must satisfy the Telegram payload
  limits (see 'mkStarsInvoiceRequest').
POST-CONTRACT: The invoice message is dispatched via the Telegram
  interpreter; the resulting 'Response' is discarded. Nothing is written to
  the DB.
-}
topUpInvoice :: Text -> ChatId -> StarsPackage -> ScenarioProgram Script serviceLib ()
topUpInvoice botName chatId pkg = do
    logInfo "stars invoice sent"
    void $
        evalScript $
            tgScript botName $
                Tg.sendInvoice (mkStarsInvoiceRequest chatId pkg)

{- | Credit a completed Telegram Stars payment into the @stars_payments@
ledger and send the user a confirmation on first credit only.
PRE-CONTRACT: The @stars_payments@ table exists (see 'Common.migration');
  the bot named by @botName@ is registered in the app's @botEnvs@; @payment@
  is the @successful_payment@ payload Telegram delivered for the charge
  identified by 'successfulPaymentTelegramPaymentChargeId'.
POST-CONTRACT: Idempotency — exactly one run per
  'successfulPaymentTelegramPaymentChargeId' returns 'CreditedNow' and
  inserts the ledger row; every re-delivery of the same charge id returns
  'DuplicateCharge' and writes nothing (the insert is
  @ON CONFLICT (telegram_payment_charge_id) DO NOTHING@ and the empty
  returning list reports the conflict). A
  'successfulPaymentInvoicePayload' matching no package in @packages@
  returns 'UnknownPayload' with no DB write and no confirmation (dead-end
  for manual review). The confirmation message is sent only on
  'CreditedNow'; a failed confirmation send is logged and swallowed — it
  can never fail or roll back the credit.
-}
creditStarsPayment ::
    Text ->
    [StarsPackage] ->
    ChatId ->
    UserId ->
    SuccessfulPayment ->
    ScenarioProgram Script serviceLib CreditedStatus
creditStarsPayment botName packages chatId userId payment =
    case Foldable.find ((== payload) . starsPackagePayload) packages of
        Nothing -> do
            withLogContext
                [("invoice_payload", payload), ("charge_id", chargeId)]
                $ logError "unknown invoice payload"
            pure UnknownPayload
        Just pkg -> do
            now <- getDateTime
            credited <-
                evalScript $
                    dbScript simpleDb ReadWrite $
                        insertStarsPaymentRow
                            now
                            chargeId
                            (userIdNum userId)
                            (fromIntegral (successfulPaymentTotalAmount payment))
                            (fromIntegral (starsPackageCurrencyAmount pkg))
                            payload
            case credited of
                [] -> do
                    withLogEntry "charge_id" chargeId $
                        logWarn "duplicate stars payment delivery ignored"
                    pure DuplicateCharge
                row : _ -> do
                    withLogEntry "charge_id" chargeId $
                        logInfo "stars payment credited"
                    sendCreditConfirmation botName chatId pkg
                    pure (CreditedNow row)
  where
    -- | Invoice payload echoed back by Telegram.
    payload = successfulPaymentInvoicePayload payment

    -- | Unique Telegram charge id serving as the ledger idempotency key.
    chargeId = successfulPaymentTelegramPaymentChargeId payment

    -- | Narrow the Telegram user id to the ledger's BIGINT column type.
    userIdNum :: UserId -> Int64
    userIdNum (UserId i) = fromIntegral i

-- | Idempotently insert one credited Stars payment keyed by the Telegram
-- payment charge id and report what landed.
-- POST-CONTRACT: Empty result means the charge id was already present
-- (UNIQUE conflict) — no row was written; otherwise the result holds exactly
-- the single inserted row.
insertStarsPaymentRow ::
    UTCTime ->
    Text ->
    Int64 ->
    Int32 ->
    Int64 ->
    Text ->
    DBScript SimpleDb [StarsPayment]
insertStarsPaymentRow now chargeId userId stars fiatAmount payload =
    runQuery $ \db ->
        runInsertReturningList $
            insertOnConflict
                (_starsPayments db)
                ( insertExpressions
                    [ StarsPayment
                        { starsPaymentId = default_
                        , starsPaymentTelegramPaymentChargeId = val_ chargeId
                        , starsPaymentUserId = just_ (val_ userId)
                        , starsPaymentStars = just_ (val_ stars)
                        , starsPaymentCurrencyAmount = just_ (val_ fiatAmount)
                        , starsPaymentInvoicePayload = just_ (val_ payload)
                        , starsPaymentCreatedAt = just_ (val_ now)
                        }
                    ]
                )
                (conflictingFields starsPaymentTelegramPaymentChargeId)
                onConflictDoNothing

{- | Best-effort confirmation message for a credited Stars payment.
PRE-CONTRACT: The bot named by @botName@ is registered in the app's @botEnvs@.
POST-CONTRACT: Never propagates a synchronous Telegram-send failure: a
  failed send is logged and swallowed, so the already-committed credit can
  never be rolled back or reported as failed.
-}
sendCreditConfirmation :: Text -> ChatId -> StarsPackage -> ScenarioProgram Script serviceLib ()
sendCreditConfirmation botName chatId pkg =
    void $
        runSafely @SomeException $
            evalScript $
                tgScript botName $
                    Tg.sendMessage (defSendMessage (SomeChatId chatId) (creditText pkg))
  where
    -- | User-facing confirmation text for the credited package.
    creditText :: StarsPackage -> Text
    creditText p =
        "✅ Top-up credited: "
            <> starsPackageTitle p
            <> " — "
            <> tshow (starsPackageStars p)
            <> " ⭐️. Thank you for supporting the circus!"
