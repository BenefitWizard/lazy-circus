{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Unit tests for the library Telegram @Then@-constructors
('LazyCircus.Testing.Bdd.Tg') over journal mocks (plan task T9).

Each test builds an observation journal via 'newScenarioState', appends a
synthetic @ObsTg*@ sequence (reply texts, a keyboard reply, a reaction, a
deletion, a document, an app-specific observation), and executes the
constructors' dialog actions through the canonical @tgTest@ runner with a bot
driver that ignores every update — no live handler and no PostgreSQL: the
journal is the only producer of observations, exactly as a BDD runner's steps
would observe it.
-}
module Bdd.TgSpec (spec) where

import RIO
import RIO.Set qualified as Set
import RIO.Text qualified as T
import Test.Hspec

import LazyCircus.App.Service (NoServiceLib (..))
import LazyCircus.Testing.Bdd.Journal
    ( DialogState (..)
    , Observation (..)
    , ScenarioState (..)
    , appendObservation
    , newScenarioState
    , readObservations
    )
import LazyCircus.Testing.Bdd.Step (StepDef (..))
import LazyCircus.Testing.Bdd.Tg
    ( botDeletesMessage
    , botReplyContains
    , botRepliesWithKeyboard
    , botRepliesWithMessage
    , botReactsTo
    , botSendsDocument
    )
import LazyCircus.Testing.Performer (Mocks, TestConfig)
import LazyCircus.Testing.TgTest
    ( TgTestError (..)
    , TelegramTestScript
    , defaultTgTestConfig
    , guardWith
    , tgTest
    )
import Telegram.Bot.API (ChatId (..), SomeReplyMarkup (..), Update)
import Telegram.Bot.API.Types
    ( InlineKeyboardButton (..)
    , InlineKeyboardMarkup (..)
    , MessageId (..)
    )

spec :: Spec
spec = describe "Telegram Then-constructors (journal mocks)" $ do
    it "botRepliesWithMessage consumes exactly the matching message" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        let journal = ssLog st0
        atomically $ do
            appendObservation journal (tgMsg "first" (MessageId 0))
            appendObservation journal (tgMsg "second" (MessageId 1))
        result <- runDialogScript (thenAction (botRepliesWithMessage "second") st0)
        case result of
            Left err -> expectationFailure ("step aborted: " <> show err)
            Right (st1, emitted) -> do
                emitted `shouldBe` Nothing
                -- one await on ObsTgMessage consumes exactly ONE message: the match
                ssConsumed st1 `shouldBe` Set.singleton 1
                dsLastReply (ssDialog st1) `shouldBe` Just "second"

    it "botReplyContains checks the last reply without consuming (And-continuation)" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        let journal = ssLog st0
        atomically $ do
            appendObservation journal (tgMsg "first" (MessageId 0))
            appendObservation journal (tgMsg "second" (MessageId 1))
        -- before anything is consumed the continuation aborts instead of waiting
        tooEarly <- runDialogScript (thenAction (botReplyContains "any") st0)
        case tooEarly of
            Left (TgTestGuardFailed reason) ->
                reason `shouldSatisfy` ("nothing has been consumed" `T.isInfixOf`)
            Left other -> expectationFailure ("expected a guard failure, got: " <> show other)
            Right _ -> expectationFailure "expected the continuation to refuse an empty dialog"
        -- a preceding reply step consumes the message...
        st1 <- expectStepSuccess (runDialogScript (thenAction (botRepliesWithMessage "second") st0))
        -- ...and the And-continuation re-inspects it: NO wait, NO consumption
        result <- runDialogScript (thenAction (botReplyContains "con") st1)
        case result of
            Left err -> expectationFailure ("continuation aborted: " <> show err)
            Right (st2, _) -> do
                ssConsumed st2 `shouldBe` Set.singleton 1
                dsLastReply (ssDialog st2) `shouldBe` Just "second"
                readObservations journal
                    `shouldReturn` [tgMsg "first" (MessageId 0), tgMsg "second" (MessageId 1)]
                -- a failed fragment check leaves everything untouched as well
                mismatch <- runDialogScript (thenAction (botReplyContains "never-there") st2)
                case mismatch of
                    Left (TgTestGuardFailed reason) ->
                        reason `shouldSatisfy` ("does not contain" `T.isInfixOf`)
                    Left other -> expectationFailure ("expected a guard failure, got: " <> show other)
                    Right _ -> expectationFailure "expected the fragment check to fail"

    it "botRepliesWithKeyboard sets dsLastKeyboard from the consumed message" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        let journal = ssLog st0
        atomically (appendObservation journal (tgKeyboardMsg "choose:" (MessageId 0)))
        result <- runDialogScript (thenAction botRepliesWithKeyboard st0)
        case result of
            Left err -> expectationFailure ("step aborted: " <> show err)
            Right (st1, _) -> do
                dsLastReply (ssDialog st1) `shouldBe` Just "choose:"
                isJust (dsLastKeyboard (ssDialog st1)) `shouldBe` True
                -- a later plain-message reply clears the keyboard again
                atomically (appendObservation journal (tgMsg "plain" (MessageId 1)))
                result2 <- runDialogScript (thenAction (botRepliesWithMessage "plain") st1)
                case result2 of
                    Left err -> expectationFailure ("step aborted: " <> show err)
                    Right (st2, _) -> do
                        dsLastReply (ssDialog st2) `shouldBe` Just "plain"
                        isNothing (dsLastKeyboard (ssDialog st2)) `shouldBe` True
                        ssConsumed st2 `shouldBe` Set.fromList [0, 1]

    it "predicates skip ObsApp entries and never consume them" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        let journal = ssLog st0
        atomically $ do
            appendObservation journal (ObsApp ())
            appendObservation journal (tgMsg "real" (MessageId 0))
        result <- runDialogScript (thenAction (botRepliesWithMessage "real") st0)
        case result of
            Left err -> expectationFailure ("step aborted: " <> show err)
            Right (st1, _) -> do
                -- only the ObsTgMessage was consumed; the ObsApp entry (number 0)
                -- was skipped over and stays available
                ssConsumed st1 `shouldBe` Set.singleton 1
                readObservations journal `shouldReturn` [ObsApp (), tgMsg "real" (MessageId 0)]

    it "botReactsTo, botDeletesMessage and botSendsDocument consume their kinds without touching the dialog" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        let journal = ssLog st0
        atomically $ do
            appendObservation journal ObsTgReaction{obsTargetMsgId = Just (MessageId 5)}
            appendObservation journal ObsTgDelete{obsTargetMsgId = Just (MessageId 6)}
            appendObservation journal ObsTgDocument{obsChatId = Just (ChatId 1), obsFileId = Nothing}
        let script = do
                (st1, _) <- thenAction botReactsTo st0
                (st2, _) <- thenAction botDeletesMessage st1
                thenAction botSendsDocument st2
        result <- runDialogScript script
        case result of
            Left err -> expectationFailure ("steps aborted: " <> show err)
            Right (st3, _) -> do
                ssConsumed st3 `shouldBe` Set.fromList [0, 1, 2]
                -- reactions, deletions and documents are not dialog replies
                dsLastReply (ssDialog st3) `shouldBe` Nothing
                isNothing (dsLastKeyboard (ssDialog st3)) `shouldBe` True

    it "a reply that never arrives times out with AwaitTimeout and consumes nothing" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        let journal = ssLog st0
        atomically (appendObservation journal (tgMsg "other" (MessageId 0)))
        result <- runDialogScript (thenAction (botRepliesWithMessage "never-sent") st0)
        case result of
            Left (TgTestGuardFailed reason) -> do
                reason `shouldSatisfy` ("timed out" `T.isInfixOf`)
                reason `shouldSatisfy` ("waiting for a reply \"never-sent\"" `T.isInfixOf`)
            Left other -> expectationFailure ("expected a timeout guard, got: " <> show other)
            Right _ -> expectationFailure "expected the step to time out"
        -- the failed wait consumed nothing and mutated nothing
        readObservations journal `shouldReturn` [tgMsg "other" (MessageId 0)]
        retry <- runDialogScript (thenAction (botRepliesWithMessage "other") st0)
        case retry of
            Left err -> expectationFailure ("the timed-out wait consumed the message: " <> show err)
            Right (st1, _) -> ssConsumed st1 `shouldBe` Set.singleton 0

--------------------------------------------------------------------------------
-- Fixtures and harness
--------------------------------------------------------------------------------

-- | A bot text-message observation addressed to chat 1.
tgMsg :: Text -> MessageId -> Observation ()
tgMsg txt mid =
    ObsTgMessage
        { obsChatId = Just (ChatId 1)
        , obsText = txt
        , obsMsgId = mid
        , obsMarkup = Nothing
        }

-- | A bot text-message observation carrying a one-button inline keyboard.
tgKeyboardMsg :: Text -> MessageId -> Observation ()
tgKeyboardMsg txt mid =
    ObsTgMessage
        { obsChatId = Just (ChatId 1)
        , obsText = txt
        , obsMsgId = mid
        , obsMarkup = Just confirmKeyboard
        }

-- | A one-button inline keyboard attached to the synthetic keyboard reply.
confirmKeyboard :: SomeReplyMarkup
confirmKeyboard =
    SomeInlineKeyboardMarkup
        InlineKeyboardMarkup
            { inlineKeyboardMarkupInlineKeyboard = [[confirmButton]]
            }

-- | The single button of 'confirmKeyboard'.
confirmButton :: InlineKeyboardButton
confirmButton =
    InlineKeyboardButton
        { inlineKeyboardButtonText = "confirm"
        , inlineKeyboardButtonUrl = Nothing
        , inlineKeyboardButtonCallbackData = Just "confirm"
        , inlineKeyboardButtonWebApp = Nothing
        , inlineKeyboardButtonLoginUrl = Nothing
        , inlineKeyboardButtonSwitchInlineQuery = Nothing
        , inlineKeyboardButtonSwitchInlineQueryCurrentChat = Nothing
        , inlineKeyboardButtonSwitchInlineQueryChosenChat = Nothing
        , inlineKeyboardButtonCallbackGame = Nothing
        , inlineKeyboardButtonPay = Nothing
        }

-- | Extracts the dialog action of a library Then definition.
-- PRE-CONTRACT: The definition comes from 'LazyCircus.Testing.Bdd.Tg' (always
-- a 'DialogDef').
thenAction ::
    StepDef TelegramTestScript () (ScenarioState app) () ->
    ScenarioState app ->
    TelegramTestScript (ScenarioState app, Maybe ())
thenAction (DialogDef _ _ act) = act
thenAction (GivenDef _ _) = \st ->
    guardWith "library Then definitions are DialogDefs, never GivenDefs" False
        >> pure (st, Nothing)

-- | Runs a dialog script through the canonical @tgTest@ runner with a bot
-- driver that ignores every update: no live handler runs and no database is
-- touched — the journal appended to by the test is the only producer of
-- observations.
runDialogScript :: TelegramTestScript a -> IO (Either TgTestError a)
runDialogScript script = do
    (_mailboxes, result) <- tgTest defaultTgTestConfig noBot script
    pure result
  where
    -- | A bot driver ignoring every update (the journal is filled by the test).
    noBot :: TestConfig () -> Mocks NoServiceLib -> IO (Update -> IO ())
    noBot _ _ = pure (\_ -> pure ())

-- | Unwraps a successful dialog run or fails the enclosing example.
expectStepSuccess :: IO (Either TgTestError (ScenarioState app, a)) -> IO (ScenarioState app)
expectStepSuccess action = action >>= either failure (pure . fst)
  where
    -- | Fails the example; never returns ('expectationFailure' throws).
    failure err =
        expectationFailure ("step aborted: " <> show err)
            >> error "unreachable: expectationFailure always throws"
