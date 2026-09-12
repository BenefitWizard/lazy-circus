{-# LANGUAGE OverloadedStrings #-}

{- | Telegram Stars (XTR) operations spec: the pure builders
('LazyCircus.Telegram.Stars.mkStarsInvoiceRequest',
'LazyCircus.Telegram.Stars.mkPreCheckoutApproval') and the mocked
@sendInvoice@ / @answerPreCheckoutQuery@ capture of the test performer
('OutSendInvoice' / 'OutAnswerPreCheckoutQuery' in the outgoing mailbox).

Mirrors the 'TgMockMailboxSpec' setup: a 'DefaultApp' with one Telegram bot
(@demo-bot@) registered, driven through 'runScenarioProgram' under the test
performer; the mailbox is drained destructively via 'readOutgoingMailbox'.
-}
module TgStarsOpsSpec (spec) where

import RIO
import Test.Hspec

import DemoEnv (DemoConfig (..), defaultDemoConfig, withDemoApp)
import LazyCircus (tgScript)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Scenario (ScenarioProgram, evalScript)
import LazyCircus.Scene.Telegram.Lang qualified as Tg (answerPreCheckoutQuery, sendInvoice)
import LazyCircus.Script (Script)
import LazyCircus.Telegram.Stars
    ( StarsPackage (..)
    , mkPreCheckoutApproval
    , mkStarsInvoiceRequest
    )
import LazyCircus.Testing.Performer
    ( OutgoingKind (..)
    , OutgoingMessage (..)
    , readOutgoingMailbox
    , runScenarioProgram
    , runWithDefaultMocks
    )
import SimpleServiceLib (AllServices)
import Telegram.Bot.API
    ( ChatId (..)
    , Message
    , Response
    , SomeChatId (..)
    , answerPreCheckoutQueryOk
    , answerPreCheckoutQueryPreCheckoutQueryId
    , messageMessageId
    , responseOk
    , responseResult
    , sendInvoiceChatId
    , sendInvoiceCurrency
    , sendInvoiceDescription
    , sendInvoicePayload
    , sendInvoicePrices
    , sendInvoiceProviderToken
    , sendInvoiceTitle
    )
import Telegram.Bot.API.Types (MessageId (..))
import Telegram.Bot.API.Types.LabeledPrice (LabeledPrice (..))

-- | Demo configuration that registers one Telegram bot (@demo-bot@) so that
-- @sendInvoice@ / @answerPreCheckoutQuery@ effects are captured by the test
-- performer's mailbox.
botTestConfig :: DemoConfig
botTestConfig = defaultDemoConfig{cfgTgToken = Just "123456:test-token"}

-- | Run an action with a 'DefaultApp' that has @demo-bot@ configured.
withBotTestApp :: (DefaultApp AllServices -> IO ()) -> IO ()
withBotTestApp action = withDemoApp botTestConfig $ \app -> action app

-- | A representative Stars package: all fields distinct so field swaps show up.
testPackage :: StarsPackage
testPackage =
    StarsPackage
        { starsPackageTitle = "Circus Ticket"
        , starsPackageDescription = "One admission to the big top"
        , starsPackagePayload = "ticket-001"
        , starsPackageStars = 150
        , starsPackageCurrencyAmount = 199
        }

-- | Send a Stars invoice for the given package as @demo-bot@ to the given chat,
-- returning the mock 'Response'.
sendInvoiceTo :: ChatId -> StarsPackage -> ScenarioProgram Script serviceLib (Response Message)
sendInvoiceTo chatId pkg =
    evalScript $
        tgScript "demo-bot" $
            Tg.sendInvoice (mkStarsInvoiceRequest chatId pkg)

-- | Approve a pre-checkout query as @demo-bot@ via 'mkPreCheckoutApproval'.
answerPreCheckout :: Text -> ScenarioProgram Script serviceLib ()
answerPreCheckout queryId =
    void $
        evalScript $
            tgScript "demo-bot" $
                Tg.answerPreCheckoutQuery (mkPreCheckoutApproval queryId)

spec :: Spec
spec = aroundAll withBotTestApp $ do
    describe "TgMock sendInvoice" $ do
        it "publishes exactly one OutSendInvoice with a fresh incremental id and the package title" $ \app -> do
            (mocks, resp) <-
                runWithDefaultMocks app $
                    runScenarioProgram $ sendInvoiceTo (ChatId 7) testPackage

            msgs <- readOutgoingMailbox mocks
            length msgs `shouldBe` 1
            let [invoiceMsg] = msgs
            omKind invoiceMsg `shouldBe` OutSendInvoice
            omChatId invoiceMsg `shouldBe` Just (ChatId 7)
            omText invoiceMsg `shouldBe` Just (starsPackageTitle testPackage)
            -- first fresh id of the mock's incremental counter
            omMessageId invoiceMsg `shouldBe` Just (MessageId 0)

            -- the returned Response reports success and carries the stamped id
            responseOk resp `shouldBe` True
            messageMessageId (responseResult resp) `shouldBe` MessageId 0

        it "assigns strictly increasing message ids across invoice sends, stamped onto each response" $ \app -> do
            (mocks, (resp1, resp2)) <-
                runWithDefaultMocks app $
                    runScenarioProgram $ do
                        r1 <- sendInvoiceTo (ChatId 7) testPackage
                        r2 <- sendInvoiceTo (ChatId 9) testPackage
                        pure (r1, r2)

            msgs <- readOutgoingMailbox mocks
            map omKind msgs `shouldBe` [OutSendInvoice, OutSendInvoice]
            map omChatId msgs `shouldBe` [Just (ChatId 7), Just (ChatId 9)]
            [mid | Just mid <- map omMessageId msgs] `shouldBe` [MessageId 0, MessageId 1]
            messageMessageId (responseResult resp1) `shouldBe` MessageId 0
            messageMessageId (responseResult resp2) `shouldBe` MessageId 1

    describe "TgMock answerPreCheckoutQuery" $ do
        it "publishes one OutAnswerPreCheckoutQuery carrying the query id as omText" $ \app -> do
            (mocks, ()) <-
                runWithDefaultMocks app $
                    runScenarioProgram $ answerPreCheckout "pcq-42"

            msgs <- readOutgoingMailbox mocks
            length msgs `shouldBe` 1
            let [answer] = msgs
            omKind answer `shouldBe` OutAnswerPreCheckoutQuery
            omText answer `shouldBe` Just "pcq-42"
            -- a pre-checkout answer targets a query, not a chat
            omChatId answer `shouldBe` Nothing

    describe "mkStarsInvoiceRequest (pure)" $ do
        it "builds a Stars-mode invoice request addressed to the given chat for an arbitrary package" $ \_app -> do
            let chatId = ChatId 42
                req = mkStarsInvoiceRequest chatId testPackage
            sendInvoiceChatId req `shouldBe` chatId
            -- the two fields that switch the invoice into Stars mode
            sendInvoiceProviderToken req `shouldBe` ""
            sendInvoiceCurrency req `shouldBe` "XTR"
            -- everything else derives from the package
            sendInvoiceTitle req `shouldBe` starsPackageTitle testPackage
            sendInvoiceDescription req `shouldBe` starsPackageDescription testPackage
            sendInvoicePayload req `shouldBe` starsPackagePayload testPackage

        it "carries a single price line labelled with the title at the package's Stars price" $ \_app -> do
            let prices = sendInvoicePrices (mkStarsInvoiceRequest (ChatId 42) testPackage)
            length prices `shouldBe` 1
            map labeledPriceLabel prices `shouldBe` [starsPackageTitle testPackage]
            map labeledPriceAmount prices `shouldBe` [starsPackageStars testPackage]

    describe "mkPreCheckoutApproval (pure)" $ do
        it "approves the checkout and carries the query id" $ \_app -> do
            let approval = mkPreCheckoutApproval "pcq-77"
            answerPreCheckoutQueryPreCheckoutQueryId approval `shouldBe` "pcq-77"
            answerPreCheckoutQueryOk approval `shouldBe` True
