{-# LANGUAGE OverloadedStrings #-}

{- | Reaction-smoke vertical acceptance for the BDD stack: a full @.feature@ →
'gherkinSpec' → reaction-bot round trip that NEVER contacts PostgreSQL.

The bot under test is a hand-built 'LazyCircus.App.Default.DefaultApp' whose
pool create action is 'fail' ('TestSupport.DbFreeApp.mkDbFreeApp'), so the
smoke passes with PostgreSQL stopped; the scenario touches only the Telegram
sub-language.

The round trip: the inline feature is turned into an hspec tree by
'gherkinSpec'; the STATIC registry mixes the library dictionary —
'LazyCircus.Testing.Bdd.Tg.botReactsWith' (matching the step's quoted emoji
capture against the consumed reaction's payload projection) and
'LazyCircus.Testing.Bdd.Tg.reactionIsBig' (the strict And-continuation on the
big-animation flag) — with spec-local digest pins, and the @When@ phase is
'LazyCircus.Testing.Bdd.Tg.userSends'.

The bot's buildAction mirrors the demo's dispatch shape
('BotHandler.dispatch' reduced to reactions): a @\/react@ command reacts to
the user's message with 👍 ('LazyCircus.Telegram.Types.fromTgEmoji' — its
first consumer) leaving @is_big@ unset, and a @\/reactbig@ command reacts
with 🔥 and @is_big = Just True@.

This spec is also the blessing ground for the extended 'ObsTgReaction'
observation shape (target id plus the reaction list and big-animation flag of
the send request in the shared journal): the full shape survives the
scenarios below, satisfying the journal's blessing rule.

Coverage: (1) a reaction observed with its emoji payload; (2) a big reaction
pinned by payload AND the strict is-big continuation; (3) the digest pins —
the target is the user's message (deterministic 'MessageId' 1: the update
factory starts at @update_id = 1@, the message id mirrors it and a fresh
factory backs every scenario run) and the honest @Nothing@ of the unset
@is_big@ in the @\/react@ scenario; (4) the is-big continuation's refusal
before a reaction is consumed (the reaction IS journaled, just not consumed).
-}
module Bdd.ReactionSpec (spec) where

import LazyCircus (tgScript)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.App.Service (NoServiceLib)
import LazyCircus.Scenario (ScenarioProgram, evalScript)
import LazyCircus.Scene.Telegram.Lang qualified as Tg (setMessageReaction)
import LazyCircus.Script (Script)
import LazyCircus.Telegram.Types (TgEmoji (..), fromTgEmoji)
import LazyCircus.Testing.Bdd.Given (appContextFor)
import LazyCircus.Testing.Bdd.Journal
    ( DialogState (..)
    , Observation (..)
    , ReactionDigest (..)
    , ScenarioState (..)
    , freshScenarioState
    )
import LazyCircus.Testing.Bdd.Runner
    ( FeatureSource (..)
    , ScenarioBootstrap
    , ScenarioRegistry
    , ScenarioVerifier
    , expectScenarioSuccess
    , gherkinSpec
    )
import LazyCircus.Testing.Bdd.Step (StepDef, StepOutcome (..), givenDef, mkRegistry, thenDef)
import LazyCircus.Testing.Bdd.Tg
    ( botReactsWith
    , reactionIsBig
    , tgTestBootstrap
    , userSends
    )
import LazyCircus.Testing.Performer
    ( Mocks
    , TestConfig (..)
    , runScenarioProgram
    , runWithConfig
    )
import LazyCircus.Testing.TgTest
    ( TelegramTestScript
    , TgTestConfig (..)
    , defaultTgTestConfig
    , guardWith
    , tgeDescription
    , tgTestWithMocks
    )
import RIO
import RIO.Text qualified as T
import Telegram.Bot.API
    ( ChatId
    , ReactionType (..)
    , SomeChatId (..)
    , Update
    , defSetMessageReaction
    , messageMessageId
    , messageText
    , setMessageReactionRequestIsBig
    , setMessageReactionRequestReaction
    , updateMessage
    )
import Telegram.Bot.API.Types (MessageId (..))
import Telegram.Bot.API.GettingUpdates (updateChatId)
import Test.Hspec
import TestSupport.DbFreeApp (mkDbFreeApp)

--------------------------------------------------------------------------------
-- The spec tree
--------------------------------------------------------------------------------

-- | The vertical acceptance: the reaction feature runs embedded in this tree
-- (so the runner's meta-test and ambiguity probe are part of it).
spec :: Spec
spec = do
    app <- runIO (mkDbFreeApp reactionBotName)
    describe "Reaction smoke (feature -> gherkinSpec -> reaction bot, no PostgreSQL)" $
        gherkinSpec
            (FeatureInline "reaction feature" reactionFeature)
            (\_ -> pure reactionStepRegistry)
            (tgTestBootstrap defaultTgTestConfig (buildReactionAction app))
            reactionVerifier
    describe "Reaction is-big refusal (feature -> gherkinSpec -> guard failure, no PostgreSQL)" $ do
        refusalReason <- runIO (newIORef (Nothing :: Maybe Text))
        gherkinSpec
            (FeatureInline "reaction is-big refusal feature" refusalFeature)
            (\_ -> pure reactionStepRegistry)
            (refusalBootstrap defaultTgTestConfig (buildReactionAction app) refusalReason)
            (refusalVerifier refusalReason)

--------------------------------------------------------------------------------
-- The reaction feature and its registry
--------------------------------------------------------------------------------

-- | The bot name the scenarios address (@tgScript@ resolves it).
reactionBotName :: Text
reactionBotName = "reaction-bot"

-- | The emoji text of the 👍 reaction payload ('textDisplay ThumbUp' — the
-- same projection 'fromTgEmoji' builds the payload from, so the feature text,
-- the digest pin and the request stay in sync by construction).
thumbUpEmoji :: Text
thumbUpEmoji = textDisplay ThumbUp

-- | The emoji text of the 🔥 reaction payload (built by hand — 'TgEmoji' has
-- no fire).
bigFireEmoji :: Text
bigFireEmoji = "🔥"

-- | The 👍 reaction payload of the @\/react@ command.
thumbUpReaction :: ReactionType
thumbUpReaction = fromTgEmoji ThumbUp

-- | The 🔥 reaction payload of the @\/reactbig@ command.
bigFireReaction :: ReactionType
bigFireReaction = ReactionTypeEmoji "emoji" bigFireEmoji

-- | The message id the factory assigns the scenario's first user message:
-- a fresh 'LazyCircus.Testing.Updates.UpdateFactory' starts at
-- @update_id = 1@, the message id mirrors the update id, and every scenario
-- run gets a fresh factory — so the first @userSends@ of a scenario always
-- addresses 'MessageId' 1.
firstUserMessageId :: MessageId
firstUserMessageId = MessageId 1

-- | The smoke's feature document: a 👍 reaction observed with its payload and
-- the digest pins (target + the honest unset @is_big@), and a 🔥 reaction
-- pinned by payload plus the strict is-big continuation.
reactionFeature :: Text
reactionFeature =
    T.unlines
        [ "Feature: Reaction bot dialog"
        , ""
        , "  Scenario: reacts to the user's message with a thumbs up"
        , "    Given the reaction bot is awake"
        , "    When the user sends \"/react\""
        , "    Then the bot reacts with \"" <> thumbUpEmoji <> "\""
        , "    And the reaction digest targets the user's message"
        , "    And the reaction digest leaves is_big unset"
        , ""
        , "  Scenario: reacts with a big fire"
        , "    Given the reaction bot is awake"
        , "    When the user sends \"/reactbig\""
        , "    Then the bot reacts with \"" <> bigFireEmoji <> "\""
        , "    And the reaction is big"
        ]

-- | @the reaction digest targets the user's message@ — And-continuation
-- pinning the target message id of the last consumed reaction's digest
-- against 'firstUserMessageId' (the deterministic id of the scenario's first
-- user message).
--
-- PRE-CONTRACT: A reaction has been consumed by a previous step (e.g.
-- 'botReactsWith'), so 'dsLastReaction' holds its digest — the step aborts
-- with an explanatory reason otherwise.
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not.
digestTargetsUserMessage :: StepDef TelegramTestScript c (ScenarioState app) a
digestTargetsUserMessage =
    thenDef "the reaction digest targets the user's message" $ \_params st ->
        case dsLastReaction (ssDialog st) of
            Nothing ->
                guardWith noConsumedReactionReason False
                    >> pure (st, Nothing)
            Just digest -> do
                guardWith
                    ("expected the reaction's target to be " <> tshow (Just firstUserMessageId) <> ", got: " <> tshow (rdTargetMsgId digest))
                    (rdTargetMsgId digest == Just firstUserMessageId)
                pure (st, Nothing)

-- | @the reaction digest leaves is_big unset@ — the honest-absence pin:
-- 'rdEmojis' is exactly the 👍 payload while 'rdIsBig' is 'Nothing' (the
-- @\/react@ request leaves the flag unset), proving the digest's 'Maybe'
-- projection observes the ABSENCE honestly.
--
-- PRE-CONTRACT: A reaction has been consumed by a previous step (e.g.
-- 'botReactsWith'), so 'dsLastReaction' holds its digest — the step aborts
-- with an explanatory reason otherwise.
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not. Each field has its own guard reason rendering expected vs actual.
digestLeavesIsBigUnset :: StepDef TelegramTestScript c (ScenarioState app) a
digestLeavesIsBigUnset =
    thenDef "the reaction digest leaves is_big unset" $ \_params st ->
        case dsLastReaction (ssDialog st) of
            Nothing ->
                guardWith noConsumedReactionReason False
                    >> pure (st, Nothing)
            Just digest -> do
                guardWith
                    ("expected the reaction's emoji list to be " <> tshow [thumbUpEmoji] <> ", got: " <> tshow (rdEmojis digest))
                    (rdEmojis digest == [thumbUpEmoji])
                guardWith
                    ("expected the reaction's is_big to be Nothing, got: " <> tshow (rdIsBig digest))
                    (rdIsBig digest == Nothing)
                pure (st, Nothing)

-- | Guard-failure message when the digest-pin steps run before any reaction
-- was consumed.
noConsumedReactionReason :: Text
noConsumedReactionReason =
    "no reaction has been consumed yet; a reaction-consuming step (e.g. 'the bot reacts with ...') must run first"

-- | The STATIC reaction registry, shared by every scenario of the feature:
-- the Given is a no-op marker, the When step and the payload step come from
-- the library dictionary, and the digest pins are spec-local.
reactionStepRegistry :: ScenarioRegistry NoServiceLib () TelegramTestScript
reactionStepRegistry = mkRegistry
    [ givenDef "the reaction bot is awake" (\_params -> pure . id)
    , userSends
    , botReactsWith
    , reactionIsBig
    , digestTargetsUserMessage
    , digestLeavesIsBigUnset
    ]

-- | Verifier: the scenario ran to success, and the journal holds exactly one
-- reaction observation and nothing else (the reaction bot only reacts — its
-- payload is already asserted by the consuming steps and the digest pins).
reactionVerifier :: ScenarioVerifier ()
reactionVerifier scenario outcome observations = do
    expectScenarioSuccess scenario outcome observations
    let isReaction ObsTgReaction{} = True
        isReaction _ = False
    unless (length (filter isReaction observations) == 1 && all isReaction observations) $
        expectationFailure $
            "expected exactly one journaled reaction and nothing else, got: " <> show observations

--------------------------------------------------------------------------------
-- The is-big refusal feature (green example for a refusing scenario)
--------------------------------------------------------------------------------

-- | The refusal feature: the is-big step runs while a reaction IS journaled
-- (the @\/reactbig@ send happened) but nothing CONSUMED it yet —
-- 'dsLastReaction' is still 'Nothing', so the step must abort with the
-- no-consumed-reaction reason.
refusalFeature :: Text
refusalFeature =
    T.unlines
        [ "Feature: Reaction is-big refusal"
        , ""
        , "  Scenario: the is-big step refuses before a reaction is consumed"
        , "    Given the reaction bot is awake"
        , "    When the user sends \"/reactbig\""
        , "    Then the reaction is big"
        ]

{- | The refusal spec's bootstrap: 'tgTestBootstrap''s twin that does NOT
fail the example when the step program aborts with a
'LazyCircus.Testing.TgTest.TgTestError' — the refusal scenario WANTS that
abort. A guard failure inside a step short-circuits the whole step program
('TelegramTestScript' is an 'ExceptT'), so the aborted run produces no
outcome of its own: the error's description is recorded in the 'IORef' for
the verifier and a synthetic successful outcome is returned, keeping the
enclosing example green so the verifier owns the refusal assertion.
-}
refusalBootstrap
    :: TgTestConfig app
    -> (TestConfig app -> Mocks serviceLib -> IO (Update -> IO ()))
    -> IORef (Maybe Text)
    -> ScenarioBootstrap serviceLib app TelegramTestScript
refusalBootstrap baseCfg buildAction errRef journal mocks =
    pure $ \stepProgram -> do
        -- per-scenario reset: a reason left by an EARLIER scenario must not
        -- mask a later scenario that never refused
        writeIORef errRef Nothing
        (_mailboxes, result) <-
            tgTestWithMocks
                baseCfg
                    { ttgPerformerConfig =
                        (ttgPerformerConfig baseCfg){tcJournal = Just journal}
                    }
                mocks
                buildAction
                stepProgram
        case result of
            Right outcome -> pure outcome
            Left err -> do
                writeIORef errRef (Just (tgeDescription err))
                pure $
                    Right $
                        StepOutcome
                            { stepOutcomeContext = appContextFor mocks
                            , stepOutcomeState = freshScenarioState journal
                            , stepOutcomeValues = []
                            , stepOutcomeSteps = []
                            }

-- | Verifier: the scenario must have REFUSED with the no-consumed-reaction
-- reason (recorded by 'refusalBootstrap'), while the journal still holds
-- exactly one reaction — the refusal is about consumption, not about a
-- missing send.
refusalVerifier :: IORef (Maybe Text) -> ScenarioVerifier ()
refusalVerifier errRef _scenario _outcome observations = do
    recorded <- readIORef errRef
    case recorded of
        Nothing ->
            expectationFailure "expected the is-big step to refuse before a reaction is consumed, but the scenario succeeded"
        Just reason ->
            unless (T.isInfixOf "no reaction has been consumed yet" reason) $
                expectationFailure $
                    "expected the no-consumed-reaction refusal, got: " <> T.unpack reason
    let isReaction ObsTgReaction{} = True
        isReaction _ = False
    unless (length (filter isReaction observations) == 1) $
        expectationFailure $
            "expected exactly one journaled reaction despite the refusal (the send happened, only the consumption did not), got: " <> show observations

--------------------------------------------------------------------------------
-- Bootstrap: the DB-free reaction app under the canonical tgTest driver
--------------------------------------------------------------------------------

-- | The reaction bot's buildAction (the 'Bdd.PollSpec.buildPollAction' shape):
-- the production-style update driver with the test performer substituted. A
-- @\/react@ text message reacts to the incoming user message with 👍 (is_big
-- left unset); a @\/reactbig@ message reacts with 🔥 and @is_big = Just True@.
-- The reaction targets the incoming message's own id
-- ('messageMessageId'), so the digest pin can assert it deterministically.
buildReactionAction
    :: DefaultApp NoServiceLib
    -> TestConfig ()
    -> Mocks NoServiceLib
    -> IO (Update -> IO ())
buildReactionAction app cfg mocks =
    pure $ \update ->
        case (updateChatId update, updateMessage update) of
            (Just chatId, Just msg) -> case messageText msg of
                Just "/react" ->
                    runWithConfig app cfg mocks $
                        runScenarioProgram (reactScenario chatId (messageMessageId msg) thumbUpReaction Nothing)
                Just "/reactbig" ->
                    runWithConfig app cfg mocks $
                        runScenarioProgram (reactScenario chatId (messageMessageId msg) bigFireReaction (Just True))
                _ -> pure ()
            _ -> pure ()

-- | The reaction scenario: sets the given reaction payload on the target
-- message, with the given big-animation flag ('Nothing' leaves @is_big@ unset
-- — the honest-absence case the digest pin asserts).
reactScenario
    :: ChatId -> MessageId -> ReactionType -> Maybe Bool
    -> ScenarioProgram Script NoServiceLib ()
reactScenario chatId targetId reaction isBig =
    void $
        evalScript $
            tgScript reactionBotName $
                Tg.setMessageReaction
                    (defSetMessageReaction (SomeChatId chatId) targetId)
                        { setMessageReactionRequestReaction = Just [reaction]
                        , setMessageReactionRequestIsBig = isBig
                        }
