{-# LANGUAGE OverloadedStrings #-}

{- | Named-messages vertical acceptance for the BDD stack: a full @.feature@ →
'gherkinSpec' → delete-bot round trip that NEVER contacts PostgreSQL.

The bot under test is a hand-built 'LazyCircus.App.Default.DefaultApp' whose
pool create action is 'fail' ('TestSupport.DbFreeApp.mkDbFreeApp'), so the
smoke passes with PostgreSQL stopped; the scenario touches only the Telegram
sub-language.

The round trip blesses the named-message pair of the library dictionary:
'LazyCircus.Testing.Bdd.Tg.userSendsAs' (@the user sends "$msg" as "$name"@ —
sends from the acting user AND binds the name capture to the 'MessageId' the
update factory assigned) and
'LazyCircus.Testing.Bdd.Tg.botDeletesNamedMessage' (@the bot deletes the
"$name"@ — consumes a deletion targeting EXACTLY the named message, unlike the
target-agnostic 'LazyCircus.Testing.Bdd.Tg.botDeletesMessage').

The bot's buildAction mirrors 'Bdd.ReactionSpec.buildReactionAction': a
@\/tick@ text message deletes the incoming message — the ACK-of-the-command
shape the feature consumer (club-manager's @\/tick@) needs. The wrong-target
twin deletes a different id instead (the classic off-by-one of mock id
arithmetic), proving the named step refuses when the bot deletes SOMETHING
ELSE while an unnamed delete would have passed.

Coverage: (1) a deletion observed with its exact target — the name resolves
to the deterministic id of the scenario's first user message ('MessageId' 1:
a fresh 'LazyCircus.Testing.Updates.UpdateFactory' starts at @update_id = 1@,
the message id mirrors it, and one factory backs the whole scenario run);
(2) two names distinguished — the second @\/tick@ binds 'MessageId' 2 and its
deletion is consumed separately (the idempotent-tick shape); (3) the refusal:
a wrong-target deletion aborts the named step with the timeout reason naming
the expected message while the journal DOES hold the wrong deletion — the
refusal is about the target, not about a missing effect.
-}
module Bdd.NamedMessagesSpec (spec) where

import LazyCircus (tgScript)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.App.Service (NoServiceLib)
import LazyCircus.Scenario (ScenarioProgram, evalScript)
import LazyCircus.Scene.Telegram.Lang qualified as Tg (deleteMessage)
import LazyCircus.Script (Script)
import LazyCircus.Testing.Bdd.Given (appContextFor)
import LazyCircus.Testing.Bdd.Journal
    ( Observation (..)
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
import LazyCircus.Testing.Bdd.Step (StepOutcome (..), givenDef, mkRegistry)
import LazyCircus.Testing.Bdd.Tg
    ( botDeletesNamedMessage
    , tgTestBootstrap
    , userSendsAs
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
    , tgeDescription
    , tgTestWithMocks
    )
import RIO
import RIO.Text qualified as T
import Telegram.Bot.API
    ( ChatId
    , Update
    , messageMessageId
    , messageText
    , updateMessage
    )
import Telegram.Bot.API.GettingUpdates (updateChatId)
import Telegram.Bot.API.Types (MessageId (..))
import Test.Hspec
import TestSupport.DbFreeApp (mkDbFreeApp)

--------------------------------------------------------------------------------
-- The spec tree
--------------------------------------------------------------------------------

-- | The vertical acceptance: the named-messages feature runs embedded in this
-- tree (so the runner's meta-test and ambiguity probe are part of it), plus
-- the wrong-target refusal twin.
spec :: Spec
spec = do
    app <- runIO (mkDbFreeApp deleteBotName)
    describe "Named messages smoke (feature -> gherkinSpec -> delete bot, no PostgreSQL)" $
        gherkinSpec
            (FeatureInline "named messages feature" namedMessagesFeature)
            (\_ -> pure namedStepRegistry)
            (tgTestBootstrap defaultTgTestConfig (buildDeleteAction honestTarget app))
            deletesVerifier
    describe "Wrong-target deletion refusal (feature -> gherkinSpec -> guard failure, no PostgreSQL)" $ do
        refusalReason <- runIO (newIORef (Nothing :: Maybe Text))
        gherkinSpec
            (FeatureInline "wrong-target deletion feature" wrongTargetFeature)
            (\_ -> pure namedStepRegistry)
            (refusalBootstrap defaultTgTestConfig (buildDeleteAction offByOneTarget app) refusalReason)
            (wrongTargetVerifier refusalReason)

--------------------------------------------------------------------------------
-- The named-messages feature and its registry
--------------------------------------------------------------------------------

-- | The bot name the scenarios address (@tgScript@ resolves it).
deleteBotName :: Text
deleteBotName = "delete-bot"

-- | The smoke's feature document: a deletion pinned to its exact named
-- target, and two names distinguished in one scenario (the idempotent-tick
-- shape — When after Then is legal; only Given placement is structural).
namedMessagesFeature :: Text
namedMessagesFeature =
    T.unlines
        [ "Feature: Named messages in deletions"
        , ""
        , "  Scenario: the bot deletes exactly the named command"
        , "    Given the delete bot is awake"
        , "    When the user sends \"/tick\" as \"message 1\""
        , "    Then the bot deletes the \"message 1\""
        , ""
        , "  Scenario: two named deletions are distinguished"
        , "    Given the delete bot is awake"
        , "    When the user sends \"/tick\" as \"message 1\""
        , "    Then the bot deletes the \"message 1\""
        , "    When the user sends \"/tick\" as \"message 2\""
        , "    Then the bot deletes the \"message 2\""
        ]

-- | The refusal feature: the bot deletes a WRONG target (the off-by-one of
-- mock id arithmetic — the incoming command is 'MessageId' 1, the bot deletes
-- 'MessageId' 2), so the named step must abort on the target mismatch.
wrongTargetFeature :: Text
wrongTargetFeature =
    T.unlines
        [ "Feature: Wrong-target deletion refusal"
        , ""
        , "  Scenario: the bot deletes something else"
        , "    Given the delete bot is awake"
        , "    When the user sends \"/tick\" as \"message 1\""
        , "    Then the bot deletes the \"message 1\""
        ]

-- | The STATIC registry, shared by every scenario of both features: the
-- Given is a no-op marker, both dialog steps come from the library
-- dictionary.
namedStepRegistry :: ScenarioRegistry NoServiceLib () TelegramTestScript
namedStepRegistry = mkRegistry
    [ givenDef "the delete bot is awake" (\_params -> pure . id)
    , userSendsAs
    , botDeletesNamedMessage
    ]

-- | Verifier: every scenario ran to success, and the journal holds ONLY
-- deletions whose targets are exactly the deterministic ids of the user
-- messages the scenario sent (the factory numbers them 1, 2, ... in send
-- order) — nothing else was deleted and nothing else was sent.
deletesVerifier :: ScenarioVerifier ()
deletesVerifier scenario outcome observations = do
    expectScenarioSuccess scenario outcome observations
    let deletes = [target | ObsTgDelete{obsTargetMsgId = Just target} <- observations]
        isDelete ObsTgDelete{} = True
        isDelete _ = False
        expectedTargets = map (MessageId . fromIntegral) [1 .. length deletes]
    unless (all isDelete observations) $
        expectationFailure $
            "expected only deletions in the journal, got: " <> show observations
    unless (deletes == expectedTargets) $
        expectationFailure $
            "expected deletions of the sent messages' own ids "
                <> show expectedTargets
                <> ", got: "
                <> show deletes

--------------------------------------------------------------------------------
-- The wrong-target refusal (green example for a refusing scenario)
--------------------------------------------------------------------------------

{- | The refusal spec's bootstrap: 'tgTestBootstrap''s twin that does NOT
fail the example when the step program aborts with a
'LazyCircus.Testing.TgTest.TgTestError' — the refusal scenario WANTS that
abort (the named step times out because the bot deleted the wrong target). A
guard failure inside a step short-circuits the whole step program
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

-- | Verifier: the scenario must have REFUSED with the named-deletion timeout
-- reason (recorded by 'refusalBootstrap'), while the journal still holds
-- exactly one deletion — of the WRONG target: the bot DID delete, the refusal
-- is about the target, not about a missing effect.
wrongTargetVerifier :: IORef (Maybe Text) -> ScenarioVerifier ()
wrongTargetVerifier errRef _scenario _outcome observations = do
    recorded <- readIORef errRef
    case recorded of
        Nothing ->
            expectationFailure "expected the named-deletion step to refuse on the wrong target, but the scenario succeeded"
        Just reason -> do
            unless (T.isInfixOf "timed out" reason) $
                expectationFailure $
                    "expected a timeout refusal, got: " <> T.unpack reason
            unless (T.isInfixOf "deletion of \"message 1\"" reason) $
                expectationFailure $
                    "expected the awaited name in the refusal, got: " <> T.unpack reason
    case observations of
        [ObsTgDelete{obsTargetMsgId = Just (MessageId 2)}] -> pure ()
        _ ->
            expectationFailure $
                "expected exactly one deletion of the wrong target (MessageId 2), got: "
                    <> show observations

--------------------------------------------------------------------------------
-- Bootstrap: the DB-free delete app under the canonical tgTest driver
--------------------------------------------------------------------------------

-- | The delete bot's target chooser: which message id a @\/tick@ deletes,
-- derived from the incoming command's own id.
type TargetChooser = MessageId -> MessageId

-- | The honest bot's chooser: deletes exactly the incoming command.
honestTarget :: TargetChooser
honestTarget = id

-- | The buggy bot's chooser: the classic off-by-one — the scenario's first
-- user command is 'MessageId' 1, the bot deletes 'MessageId' 2 (a name the
-- scenario never bound).
offByOneTarget :: TargetChooser
offByOneTarget _ = MessageId 2

-- | The delete bot's buildAction (the 'Bdd.ReactionSpec.buildReactionAction'
-- shape): the production-style update driver with the test performer
-- substituted. A @\/tick@ text message deletes the id the target chooser
-- derives from the incoming message's own id.
buildDeleteAction
    :: TargetChooser
    -> DefaultApp NoServiceLib
    -> TestConfig ()
    -> Mocks NoServiceLib
    -> IO (Update -> IO ())
buildDeleteAction chooseTarget app cfg mocks =
    pure $ \update ->
        case (updateChatId update, updateMessage update) of
            (Just chatId, Just msg) -> case messageText msg of
                Just "/tick" ->
                    runWithConfig app cfg mocks $
                        runScenarioProgram (deleteScenario chatId (chooseTarget (messageMessageId msg)))
                _ -> pure ()
            _ -> pure ()

-- | The deletion scenario: deletes the given target message.
deleteScenario :: ChatId -> MessageId -> ScenarioProgram Script NoServiceLib ()
deleteScenario chatId targetId =
    void $
        evalScript $
            tgScript deleteBotName $
                Tg.deleteMessage chatId targetId
