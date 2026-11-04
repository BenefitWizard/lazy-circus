{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Unit tests for the library Telegram @Then@-constructors
('LazyCircus.Testing.Bdd.Tg') over journal mocks.

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
import RIO.Map qualified as Map
import RIO.Set qualified as Set
import RIO.Text qualified as T
import Test.Hspec

import LazyCircus.App.Service (NoServiceLib (..))
import LazyCircus.Testing.Bdd.Journal
    ( DialogState (..)
    , Observation (..)
    , ReactionDigest (..)
    , ScenarioState (..)
    , appendObservation
    , newScenarioState
    , readObservations
    )
import LazyCircus.Testing.Bdd.Pattern (ParamName, ParamValue, StepParams (..))
import LazyCircus.Testing.Bdd.Step (StepDef (..))
import LazyCircus.Testing.Bdd.Tg
    ( botDeletesMessage
    , botDeletesNamedMessage
    , botReplyContains
    , botRepliesInMainThread
    , botRepliesInThread
    , botRepliesWithKeyboard
    , botRepliesWithMessage
    , botReactsTo
    , botReactsWith
    , botSendsDocument
    , reactionIsBig
    , userSendsAs
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
    , MessageThreadId (..)
    , ReactionType (..)
    )

spec :: Spec
spec = describe "Telegram Then-constructors (journal mocks)" $ do
    it "botRepliesWithMessage consumes exactly the matching message" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        let journal = ssLog st0
        atomically $ do
            appendObservation journal (tgMsg "first" (MessageId 0))
            appendObservation journal (tgMsg "second" (MessageId 1))
        result <- runDialogScript (thenActionWithParams [("$text", "second")] botRepliesWithMessage st0)
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
        tooEarly <- runDialogScript (thenActionWithParams [("$frag", "any")] botReplyContains st0)
        case tooEarly of
            Left (TgTestGuardFailed reason) ->
                reason `shouldSatisfy` ("nothing has been consumed" `T.isInfixOf`)
            Left other -> expectationFailure ("expected a guard failure, got: " <> show other)
            Right _ -> expectationFailure "expected the continuation to refuse an empty dialog"
        -- a preceding reply step consumes the message...
        st1 <- expectStepSuccess (runDialogScript (thenActionWithParams [("$text", "second")] botRepliesWithMessage st0))
        -- ...and the And-continuation re-inspects it: NO wait, NO consumption
        result <- runDialogScript (thenActionWithParams [("$frag", "con")] botReplyContains st1)
        case result of
            Left err -> expectationFailure ("continuation aborted: " <> show err)
            Right (st2, _) -> do
                ssConsumed st2 `shouldBe` Set.singleton 1
                dsLastReply (ssDialog st2) `shouldBe` Just "second"
                readObservations journal
                    `shouldReturn` [tgMsg "first" (MessageId 0), tgMsg "second" (MessageId 1)]
                -- a failed fragment check leaves everything untouched as well
                mismatch <- runDialogScript (thenActionWithParams [("$frag", "never-there")] botReplyContains st2)
                case mismatch of
                    Left (TgTestGuardFailed reason) ->
                        reason `shouldSatisfy` ("does not contain" `T.isInfixOf`)
                    Left other -> expectationFailure ("expected a guard failure, got: " <> show other)
                    Right _ -> expectationFailure "expected the fragment check to fail"

    it "botRepliesInThread checks the last consumed message's thread without consuming (And-continuation)" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        let journal = ssLog st0
            topicPost = (tgMsg "into the topic" (MessageId 1)){obsThreadId = Just (MessageThreadId 42)}
        -- before anything is consumed the continuation aborts instead of waiting
        tooEarly <- runDialogScript (thenActionWithParams [("$thread", "42")] botRepliesInThread st0)
        case tooEarly of
            Left (TgTestGuardFailed reason) ->
                reason `shouldSatisfy` ("nothing has been consumed" `T.isInfixOf`)
            Left other -> expectationFailure ("expected a guard failure, got: " <> show other)
            Right _ -> expectationFailure "expected the continuation to refuse an empty dialog"
        -- a preceding reply step consumes the message...
        atomically (appendObservation journal topicPost)
        st1 <- expectStepSuccess (runDialogScript (thenActionWithParams [("$text", "into the topic")] botRepliesWithMessage st0))
        -- ...and the And-continuation re-inspects its location: NO wait, NO consumption
        result <- runDialogScript (thenActionWithParams [("$thread", "42")] botRepliesInThread st1)
        case result of
            Left err -> expectationFailure ("continuation aborted: " <> show err)
            Right (st2, _) -> do
                ssConsumed st2 `shouldBe` Set.singleton 0
                -- a failed location check leaves everything untouched as well
                mismatch <- runDialogScript (thenActionWithParams [("$thread", "43")] botRepliesInThread st2)
                case mismatch of
                    Left (TgTestGuardFailed reason) ->
                        reason `shouldSatisfy` ("the last reply was sent to thread 42, expected thread 43" `T.isInfixOf`)
                    Left other -> expectationFailure ("expected a guard failure, got: " <> show other)
                    Right _ -> expectationFailure "expected the location check to fail"

    it "botRepliesInMainThread demands obsThreadId = Nothing on the last consumed message" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        let journal = ssLog st0
        -- journal order matters: the location checks inspect the HIGHEST
        -- consumed entry, so the main-chat reply must sit above the others
        atomically $ do
            appendObservation journal (tgMsg "topic post" (MessageId 0)){obsThreadId = Just (MessageThreadId 42)}
            appendObservation journal (tgDelete (MessageId 0))
            appendObservation journal (tgMsg "main-chat reply" (MessageId 1))
        -- consume the topic post...
        st1 <- expectStepSuccess (runDialogScript (thenActionWithParams [("$text", "topic post")] botRepliesWithMessage st0))
        -- ...so the main-chat check sees it and refuses
        mismatch <- runDialogScript (thenAction botRepliesInMainThread st1)
        case mismatch of
            Left (TgTestGuardFailed reason) ->
                reason `shouldSatisfy` ("the last reply was sent to thread 42, expected the main chat" `T.isInfixOf`)
            Left other -> expectationFailure ("expected a guard failure, got: " <> show other)
            Right _ -> expectationFailure "expected the location check to fail"
        -- a non-message last entry refuses too
        st2 <- expectStepSuccess (runDialogScript (thenAction botDeletesMessage st1))
        notAMessage <- runDialogScript (thenAction botRepliesInMainThread st2)
        case notAMessage of
            Left (TgTestGuardFailed reason) ->
                reason `shouldSatisfy` ("not a bot message" `T.isInfixOf`)
            Left other -> expectationFailure ("expected a guard failure, got: " <> show other)
            Right _ -> expectationFailure "expected the location check to fail"
        -- consuming the topmost entry — the main-chat reply — passes
        st3 <- expectStepSuccess (runDialogScript (thenActionWithParams [("$text", "main-chat reply")] botRepliesWithMessage st2))
        pass <- runDialogScript (thenAction botRepliesInMainThread st3)
        case pass of
            Left err -> expectationFailure ("step aborted: " <> show err)
            Right (st4, _) -> ssConsumed st4 `shouldBe` Set.fromList [0, 1, 2]

    it "botRepliesInThread refuses a non-integer thread capture before touching the dialog" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        result <- runDialogScript (thenActionWithParams [("$thread", "not-a-number")] botRepliesInThread st0)
        case result of
            Left (TgTestGuardFailed reason) ->
                reason `shouldSatisfy` ("does not parse as an integer thread id" `T.isInfixOf`)
            Left other -> expectationFailure ("expected a guard failure, got: " <> show other)
            Right _ -> expectationFailure "expected the capture check to fail"

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
                result2 <- runDialogScript (thenActionWithParams [("$text", "plain")] botRepliesWithMessage st1)
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
        result <- runDialogScript (thenActionWithParams [("$text", "real")] botRepliesWithMessage st0)
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
            appendObservation journal (tgReactionWith "👍" Nothing (MessageId 5))
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
                -- ...but the consumed reaction folded its digest
                dsLastReaction (ssDialog st3)
                    `shouldBe` Just
                        ReactionDigest
                            { rdTargetMsgId = Just (MessageId 5)
                            , rdEmojis = ["👍"]
                            , rdIsBig = Nothing
                            }

    it "botReactsWith consumes the matching reaction and folds its digest" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        let journal = ssLog st0
        atomically $ do
            appendObservation journal (tgReactionWith "👍" Nothing (MessageId 5))
            appendObservation journal (tgReactionWith "🔥" (Just True) (MessageId 6))
        result <- runDialogScript (thenActionWithParams [("$emoji", "🔥")] botReactsWith st0)
        case result of
            Left err -> expectationFailure ("step aborted: " <> show err)
            Right (st1, _) -> do
                -- only the 🔥 reaction was consumed; the 👍 one stays available
                ssConsumed st1 `shouldBe` Set.singleton 1
                dsLastReaction (ssDialog st1)
                    `shouldBe` Just
                        ReactionDigest
                            { rdTargetMsgId = Just (MessageId 6)
                            , rdEmojis = ["🔥"]
                            , rdIsBig = Just True
                            }
                -- a later bot message does not invalidate the reaction digest
                atomically (appendObservation journal (tgMsg "plain" (MessageId 0)))
                result2 <- runDialogScript (thenActionWithParams [("$text", "plain")] botRepliesWithMessage st1)
                case result2 of
                    Left err -> expectationFailure ("step aborted: " <> show err)
                    Right (st2, _) -> do
                        dsLastReply (ssDialog st2) `shouldBe` Just "plain"
                        dsLastReaction (ssDialog st2)
                            `shouldBe` Just
                                ReactionDigest
                                    { rdTargetMsgId = Just (MessageId 6)
                                    , rdEmojis = ["🔥"]
                                    , rdIsBig = Just True
                                    }
        -- no reaction carries the emoji: the step times out and consumes nothing
        mismatch <- runDialogScript (thenActionWithParams [("$emoji", "🙁")] botReactsWith st0)
        case mismatch of
            Left (TgTestGuardFailed reason) -> do
                reason `shouldSatisfy` ("timed out" `T.isInfixOf`)
                reason `shouldSatisfy` ("waiting for a \"🙁\" reaction" `T.isInfixOf`)
            Left other -> expectationFailure ("expected a timeout guard, got: " <> show other)
            Right _ -> expectationFailure "expected the step to time out"

    it "reactionIsBig refuses before a reaction is consumed, then pins the digest" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        let journal = ssLog st0
        -- before anything is consumed the continuation aborts instead of waiting
        tooEarly <- runDialogScript (thenAction reactionIsBig st0)
        case tooEarly of
            Left (TgTestGuardFailed reason) ->
                reason `shouldSatisfy` ("no reaction has been consumed" `T.isInfixOf`)
            Left other -> expectationFailure ("expected a guard failure, got: " <> show other)
            Right _ -> expectationFailure "expected the continuation to refuse an empty dialog"
        -- an unset is_big refuses (the honest Nothing)
        atomically (appendObservation journal (tgReactionWith "👍" Nothing (MessageId 5)))
        st1 <- expectStepSuccess (runDialogScript (thenAction botReactsTo st0))
        unset <- runDialogScript (thenAction reactionIsBig st1)
        case unset of
            Left (TgTestGuardFailed reason) ->
                reason `shouldSatisfy` ("left is_big unset" `T.isInfixOf`)
            Left other -> expectationFailure ("expected a guard failure, got: " <> show other)
            Right _ -> expectationFailure "expected the continuation to refuse an unset is_big"
        -- an explicitly small animation refuses too
        atomically (appendObservation journal (tgReactionWith "👎" (Just False) (MessageId 6)))
        st2 <- expectStepSuccess (runDialogScript (thenAction botReactsTo st1))
        small <- runDialogScript (thenAction reactionIsBig st2)
        case small of
            Left (TgTestGuardFailed reason) ->
                reason `shouldSatisfy` ("small animation" `T.isInfixOf`)
            Left other -> expectationFailure ("expected a guard failure, got: " <> show other)
            Right _ -> expectationFailure "expected the continuation to refuse a small animation"
        -- a consumed big reaction passes: NO wait, NO consumption
        atomically (appendObservation journal (tgReactionWith "🔥" (Just True) (MessageId 7)))
        st3 <- expectStepSuccess (runDialogScript (thenAction botReactsTo st2))
        result <- runDialogScript (thenAction reactionIsBig st3)
        case result of
            Left err -> expectationFailure ("continuation aborted: " <> show err)
            Right (st4, _) -> ssConsumed st4 `shouldBe` ssConsumed st3

    it "reaction observations compare by full structural equality (orphan Eq)" $ do
        tgReactionWith "👍" Nothing (MessageId 5) `shouldBe` tgReactionWith "👍" Nothing (MessageId 5)
        tgReactionWith "👍" Nothing (MessageId 5) `shouldNotBe` tgReactionWith "🔥" Nothing (MessageId 5)
        tgReactionWith "👍" Nothing (MessageId 5) `shouldNotBe` tgReactionWith "👍" (Just True) (MessageId 5)
        -- the orphan Eq itself: same payload, different type field
        ReactionTypeEmoji "emoji" "👍" `shouldNotBe` ReactionTypeEmoji "paid" "👍"
        -- cross-constructor is never equal, even with a shared payload text
        ReactionTypeEmoji "emoji" "👍" `shouldNotBe` ReactionTypeCustomEmoji "custom_emoji" "👍"

    it "a reply that never arrives times out with AwaitTimeout and consumes nothing" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        let journal = ssLog st0
        atomically (appendObservation journal (tgMsg "other" (MessageId 0)))
        result <- runDialogScript (thenActionWithParams [("$text", "never-sent")] botRepliesWithMessage st0)
        case result of
            Left (TgTestGuardFailed reason) -> do
                reason `shouldSatisfy` ("timed out" `T.isInfixOf`)
                reason `shouldSatisfy` ("waiting for a reply \"never-sent\"" `T.isInfixOf`)
            Left other -> expectationFailure ("expected a timeout guard, got: " <> show other)
            Right _ -> expectationFailure "expected the step to time out"
        -- the failed wait consumed nothing and mutated nothing
        readObservations journal `shouldReturn` [tgMsg "other" (MessageId 0)]
        retry <- runDialogScript (thenActionWithParams [("$text", "other")] botRepliesWithMessage st0)
        case retry of
            Left err -> expectationFailure ("the timed-out wait consumed the message: " <> show err)
            Right (st1, _) -> ssConsumed st1 `shouldBe` Set.singleton 0

    it "userSendsAs binds the sent message's id to the name and refuses a rebind" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        result <-
            runDialogScript (thenActionWithParams [("$msg", "/tick"), ("$name", "message 1")] userSendsAs st0)
        case result of
            Left err -> expectationFailure ("step aborted: " <> show err)
            Right (st1, _) -> do
                -- a fresh update factory starts at update_id = 1 and the
                -- message id mirrors it, so the first sent message is MessageId 1
                ssNamedMessages st1 `shouldBe` Map.fromList [("message 1", MessageId 1)]
                -- a second binding of the same name: guard failure listing the
                -- bound names; the state passes through unchanged
                rebind <-
                    runDialogScript
                        (thenActionWithParams [("$msg", "/again"), ("$name", "message 1")] userSendsAs st1)
                case rebind of
                    Left (TgTestGuardFailed reason) -> do
                        reason `shouldSatisfy` ("already bound" `T.isInfixOf`)
                        reason `shouldSatisfy` ("\"message 1\"" `T.isInfixOf`)
                    Left other -> expectationFailure ("expected a guard failure, got: " <> show other)
                    Right _ -> expectationFailure "expected the rebind to refuse"
                -- a DIFFERENT name still binds after a refusal (each
                -- runDialogScript is its own tgTest run with a fresh factory,
                -- so this run's first message is MessageId 1 again)
                second <-
                    runDialogScript
                        (thenActionWithParams [("$msg", "/tock"), ("$name", "message 2")] userSendsAs st1)
                case second of
                    Left err -> expectationFailure ("step aborted: " <> show err)
                    Right (st2, _) ->
                        ssNamedMessages st2
                            `shouldBe` Map.fromList [("message 1", MessageId 1), ("message 2", MessageId 1)]

    it "botDeletesNamedMessage consumes exactly the named message's deletion" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        let journal = ssLog st0
            named = st0{ssNamedMessages = Map.fromList [("m1", MessageId 6)]}
        atomically $ do
            appendObservation journal (tgDelete (MessageId 6))
            appendObservation journal (tgDelete (MessageId 9))
        result <- runDialogScript (thenActionWithParams [("$name", "m1")] botDeletesNamedMessage named)
        case result of
            Left err -> expectationFailure ("step aborted: " <> show err)
            Right (st1, _) -> do
                -- only the deletion of the NAMED target was consumed; the
                -- foreign-target deletion scanned past stays available
                ssConsumed st1 `shouldBe` Set.singleton 0
                leftover <- runDialogScript (thenAction botDeletesMessage st1)
                case leftover of
                    Left err -> expectationFailure ("step aborted: " <> show err)
                    Right (st2, _) -> ssConsumed st2 `shouldBe` Set.fromList [0, 1]

    it "botDeletesNamedMessage refuses an unknown name immediately, listing known names" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        let journal = ssLog st0
            named = st0{ssNamedMessages = Map.fromList [("known", MessageId 3)]}
        -- a deletion IS journaled: had the step waited, it would have found
        -- something — the refusal reason proves it refused on the NAME instead
        atomically (appendObservation journal (tgDelete (MessageId 3)))
        result <- runDialogScript (thenActionWithParams [("$name", "nope")] botDeletesNamedMessage named)
        case result of
            Left (TgTestGuardFailed reason) -> do
                reason `shouldSatisfy` ("is not bound" `T.isInfixOf`)
                reason `shouldSatisfy` ("\"known\"" `T.isInfixOf`)
            Left other -> expectationFailure ("expected a guard failure, got: " <> show other)
            Right _ -> expectationFailure "expected the unknown name to refuse"
        -- the refusal mutated nothing: the journaled deletion is intact
        readObservations journal `shouldReturn` [tgDelete (MessageId 3)]

    it "a wrong-target deletion times out naming the expected message" $ do
        st0 <- newScenarioState :: IO (ScenarioState ())
        let journal = ssLog st0
            named = st0{ssNamedMessages = Map.fromList [("m1", MessageId 7)]}
        -- the bot deleted SOMETHING ELSE (target 9): the step must refuse
        atomically (appendObservation journal (tgDelete (MessageId 9)))
        result <- runDialogScript (thenActionWithParams [("$name", "m1")] botDeletesNamedMessage named)
        case result of
            Left (TgTestGuardFailed reason) -> do
                reason `shouldSatisfy` ("timed out" `T.isInfixOf`)
                reason `shouldSatisfy` ("deletion of \"m1\"" `T.isInfixOf`)
                reason `shouldSatisfy` ("bound message names" `T.isInfixOf`)
            Left other -> expectationFailure ("expected a timeout guard, got: " <> show other)
            Right _ -> expectationFailure "expected the wrong-target deletion to refuse"
        -- the refused wait consumed nothing: the foreign deletion is still matchable
        retry <- runDialogScript (thenAction botDeletesMessage named)
        case retry of
            Left err -> expectationFailure ("the refused wait consumed the deletion: " <> show err)
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
        , obsThreadId = Nothing
        , obsMarkup = Nothing
        }

-- | A bot reaction observation on the given message with one emoji payload
-- and the given big-animation flag ('Nothing' = the request left @is_big@
-- unset).
tgReactionWith :: Text -> Maybe Bool -> MessageId -> Observation ()
tgReactionWith emoji isBig mid =
    ObsTgReaction
        { obsTargetMsgId = Just mid
        , obsReaction = Just [ReactionTypeEmoji "emoji" emoji]
        , obsIsBig = isBig
        }

-- | A deletion observation targeting the given message.
tgDelete :: MessageId -> Observation ()
tgDelete mid = ObsTgDelete{obsTargetMsgId = Just mid}

-- | A bot text-message observation carrying a one-button inline keyboard.
tgKeyboardMsg :: Text -> MessageId -> Observation ()
tgKeyboardMsg txt mid =
    ObsTgMessage
        { obsChatId = Just (ChatId 1)
        , obsText = txt
        , obsMsgId = mid
        , obsThreadId = Nothing
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

-- | Extracts the dialog action of a library Then definition and applies it
-- with synthetic pattern captures: the constructors of
-- 'LazyCircus.Testing.Bdd.Tg' read their expected values from the captures
-- ('LazyCircus.Testing.Bdd.Pattern.lookupParam'), so a unit test simulates
-- the runner's match by injecting the captures the definition's pattern
-- names (no step table — none of the tested definitions reads one).
-- PRE-CONTRACT: The definition comes from 'LazyCircus.Testing.Bdd.Tg' (always
-- a 'DialogDef'); @captures@ carries a value for every capture the
-- definition's pattern registers.
thenActionWithParams ::
    [(ParamName, ParamValue)] ->
    StepDef TelegramTestScript () (ScenarioState app) () ->
    ScenarioState app ->
    TelegramTestScript (ScenarioState app, Maybe ())
thenActionWithParams captures (DialogDef _ _ act) = act (StepParams captures Nothing)
thenActionWithParams captures (GivenDef _ _) = \st ->
    guardWith "library Then definitions are DialogDefs, never GivenDefs" False
        >> pure (st, Nothing)

-- | 'thenActionWithParams' with empty captures — for definitions whose
-- pattern carries no quoted span.
-- PRE-CONTRACT: The definition comes from 'LazyCircus.Testing.Bdd.Tg' (always
-- a 'DialogDef').
thenAction ::
    StepDef TelegramTestScript () (ScenarioState app) () ->
    ScenarioState app ->
    TelegramTestScript (ScenarioState app, Maybe ())
thenAction = thenActionWithParams []

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
