-- | Pure builders for Telegram Stars (XTR) payments: invoice requests and
-- pre-checkout approvals.
--
-- The Bot API switches an invoice into Stars mode via two request fields
-- (empty @provider_token@, @XTR@ currency); the price itself is a plain
-- 'LabeledPrice' in whole Stars. This module fixes those fields and derives
-- every remaining value from the 'StarsPackage' argument — no denomination is
-- hardcoded.
module LazyCircus.Telegram.Stars (
    StarsPackage (..),
    mkStarsInvoiceRequest,
    mkPreCheckoutApproval,
) where

import RIO
import Telegram.Bot.API (ChatId)
import Telegram.Bot.API.Payments
    ( AnswerPreCheckoutQueryRequest
    , SendInvoiceRequest
    , defAnswerPreCheckoutQuery
    , defSendInvoice
    )
import Telegram.Bot.API.Types.LabeledPrice (LabeledPrice (..))

-- | Description of a product sold for Telegram Stars.
--
-- Telegram Bot API payload limits: @title@ 1-32 characters,
-- @description@ 1-255 characters, @payload@ 1-128 bytes.
data StarsPackage = StarsPackage
    { starsPackageTitle          :: Text -- ^ product name shown on the invoice (1-32 characters)
    , starsPackageDescription    :: Text -- ^ product description shown on the invoice (1-255 characters)
    , starsPackagePayload        :: Text -- ^ bot-defined invoice payload echoed back in the successful payment (1-128 bytes)
    , starsPackageStars          :: Int  -- ^ price in whole Stars (XTR); the amount of the invoice's single price line
    , starsPackageCurrencyAmount :: Int  -- ^ reference price in minor units of the merchant's fiat currency, carried for dual pricing; not sent in the Stars invoice
    }

{- | Build a Stars invoice request addressed to the given chat.
PRE-CONTRACT: The 'StarsPackage' fields must satisfy the Telegram payload limits
  (title 1-32 characters, description 1-255 characters, payload 1-128 bytes);
  'starsPackageStars' must be positive.
POST-CONTRACT: The request targets @chatId@ with @providerToken = \"\"@ and
  @currency = \"XTR\"@ (Stars mode), payload taken from 'starsPackagePayload',
  and a single price line @[LabelPrice title stars]@; all optional fields are
  unset.
-}
mkStarsInvoiceRequest :: ChatId -> StarsPackage -> SendInvoiceRequest
mkStarsInvoiceRequest chatId pkg =
    defSendInvoice
        chatId
        (starsPackageTitle pkg)
        (starsPackageDescription pkg)
        (starsPackagePayload pkg)
        starsProviderToken
        starsCurrency
        [LabelPrice (starsPackageTitle pkg) (starsPackageStars pkg)]
  where
    -- | Empty provider token switches the invoice into Telegram Stars mode.
    starsProviderToken :: Text
    starsProviderToken = ""

    -- | Telegram Stars currency code.
    starsCurrency :: Text
    starsCurrency = "XTR"

{- | Build an approval for a received pre-checkout query.
PRE-CONTRACT: @queryId@ must be the identifier of a currently open pre-checkout
  query; the answer must reach Telegram within 10 seconds or the payment times
  out.
POST-CONTRACT: The request confirms the payment (@ok = True@) with no error
  message.
-}
mkPreCheckoutApproval :: Text -> AnswerPreCheckoutQueryRequest
mkPreCheckoutApproval queryId = defAnswerPreCheckoutQuery queryId True
