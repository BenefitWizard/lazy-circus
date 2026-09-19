{-# LANGUAGE NoImplicitPrelude #-}

{- | Library @Then@-phase step constructors for the Telegram dialog subset of
the BDD runner — the shared step vocabulary every app registry can reuse.

The constructors are registry-ready 'StepDef's over the canonical stack: the
dialog monad is 'TelegramTestScript' (the @tgTest@ DSL — a parameter-free
reader over the test runtime with an IO escape), and the threaded state is
'ScenarioState' (the observation journal's consumed set plus the derived
dialog view). Each constructor builds a 'thenDef' entry, so document steps
resolved as @Then@ — including @And@\/@But@ continuations, which inherit the
previous step's keyword during parsing — select them. The expected values are
read from the step text's captured parameters themselves (via
'LazyCircus.Testing.Bdd.Pattern.lookupParam'), not passed at registration
time.

Await semantics (one await = one observation): every constructor except
'botReplyContains' performs ONE 'awaitObservation' whose predicate matches
ONLY the core @ObsTg*@ constructors — app-specific 'ObsApp' entries are
skipped over and never consumed. A matched 'ObsTgMessage' folds into
'ssDialog' ('dsLastReply' from the text, 'dsLastKeyboard' from its markup).
'botReplyContains' is the And-continuation: it re-inspects the last consumed
entry via 'peekLastConsumed' — NO wait and NO consumption — asserting on
@dsLastReply@ without moving the cursor.

The module also exports 'tgTestBootstrap', the canonical @tgTest@-shaped
'LazyCircus.Testing.Bdd.Runner.ScenarioBootstrap': it executes a BDD
scenario's step program as a 'LazyCircus.Testing.TgTest.tgTestWithMocks' run
over the runner-owned mocks with the scenario's fresh journal wired in via
@tcJournal@.
-}
module LazyCircus.Testing.Bdd.Tg
    ( botRepliesWithMessage
    , botReplyContains
    , botRepliesWithKeyboard
    , botReactsTo
    , botDeletesMessage
    , botSendsDocument
    , tgTestBootstrap
    ) where

import RIO
import RIO.Text qualified as T

import LazyCircus.Testing.Bdd.Journal
    ( AwaitTimeout (..)
    , Observation (..)
    , ScenarioState
    , Sequenced (..)
    , awaitObservation
    , defaultAwaitBudgetUs
    , peekLastConsumed
    )
import LazyCircus.Testing.Bdd.Pattern (lookupParam)
import LazyCircus.Testing.Bdd.Runner (ScenarioBootstrap)
import LazyCircus.Testing.Bdd.Step (StepDef (..), thenDef)
import LazyCircus.Testing.Performer (Mocks, TestConfig (..))
import LazyCircus.Testing.TgTest
    ( TelegramTestScript
    , TgTestConfig (..)
    , guardWith
    , tgeDescription
    , tgTestWithMocks
    )
import Telegram.Bot.API (Update)
import Test.Hspec (expectationFailure)

-- | @the bot replies with "$text"@ — the bot's reply equals the step's quoted
-- capture exactly.
--
-- PRE-CONTRACT: The expected reply appears inside double quotes in the step
-- text (the pattern's @"$text"@ span) — the runner matched the step, so the
-- capture is present.
-- POST-CONTRACT: On success exactly one 'ObsTgMessage' carrying the captured
-- text has been consumed and folded into 'ssDialog'; @And@ continuations can
-- re-inspect it via 'botReplyContains'. When no unconsumed message with this
-- text appears within 'defaultAwaitBudgetUs', the step aborts the DSL with a
-- timeout reason and nothing is consumed.
botRepliesWithMessage :: StepDef TelegramTestScript c (ScenarioState app) a
botRepliesWithMessage =
    thenDef "the bot replies with \"$text\"" $ \params -> do
        let expected = fromMaybe "" (lookupParam "$text" params)
        awaitMatching ("a reply \"" <> expected <> "\"") (isReplyWithText expected)

-- | @the bot replies with a message containing "$frag"@ — And-continuation
-- asserting the LAST CONSUMED bot message contains the step's quoted capture.
--
-- PRE-CONTRACT: The expected fragment appears inside double quotes in the
-- step text (the pattern's @"$frag"@ span) — the runner matched the step, so
-- the capture is present. A previous step has already consumed an
-- 'ObsTgMessage' (checked — the step aborts with an explanatory reason
-- otherwise).
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not. On a mismatch (or when the last consumed entry is not a bot
-- message) the DSL aborts with a guard failure.
botReplyContains :: StepDef TelegramTestScript c (ScenarioState app) a
botReplyContains =
    thenDef "the bot replies with a message containing \"$frag\"" $ \params st -> do
        let fragment = fromMaybe "" (lookupParam "$frag" params)
        lastEntry <- liftIO (peekLastConsumed st)
        case lastEntry of
            Just (Sequenced _ ObsTgMessage{obsText = txt}) -> do
                guardWith (missingFragment fragment txt) (T.isInfixOf fragment txt)
                pure (st, Nothing)
            Just (Sequenced _ _) ->
                guardWith "the last consumed observation is not a bot message" False
                    >> pure (st, Nothing)
            Nothing ->
                guardWith "nothing has been consumed yet; a reply-consuming step must run first" False
                    >> pure (st, Nothing)

-- | @the bot replies with a keyboard@ — the bot's reply carries reply
-- markup (an inline or reply keyboard).
--
-- PRE-CONTRACT: None.
-- POST-CONTRACT: On success exactly one 'ObsTgMessage' carrying markup has
-- been consumed; 'dsLastKeyboard' holds that markup (presence only — the
-- markup type is opaque) and 'dsLastReply' its text. When no such message
-- appears within 'defaultAwaitBudgetUs', the step aborts with a timeout
-- reason and nothing is consumed.
botRepliesWithKeyboard :: StepDef TelegramTestScript c (ScenarioState app) a
botRepliesWithKeyboard =
    thenDef "the bot replies with a keyboard" $ \_params ->
        awaitMatching "a reply with a keyboard" isKeyboardReply

-- | @the bot reacts to a message@ — the bot set a reaction (on any message).
--
-- PRE-CONTRACT: None.
-- POST-CONTRACT: On success exactly one 'ObsTgReaction' has been consumed;
-- the dialog state is untouched (reactions are not dialog replies). Aborts
-- with a timeout reason when none appears within 'defaultAwaitBudgetUs'.
botReactsTo :: StepDef TelegramTestScript c (ScenarioState app) a
botReactsTo =
    thenDef "the bot reacts to a message" $ \_params ->
        awaitMatching "a message reaction" isReactionObs

-- | @the bot deletes a message@ — the bot deleted a message.
--
-- PRE-CONTRACT: None.
-- POST-CONTRACT: On success exactly one 'ObsTgDelete' has been consumed.
-- Aborts with a timeout reason when none appears within
-- 'defaultAwaitBudgetUs'.
botDeletesMessage :: StepDef TelegramTestScript c (ScenarioState app) a
botDeletesMessage =
    thenDef "the bot deletes a message" $ \_params ->
        awaitMatching "a message deletion" isDeleteObs

-- | @the bot sends a document@ — the bot sent a document.
--
-- PRE-CONTRACT: None.
-- POST-CONTRACT: On success exactly one 'ObsTgDocument' has been consumed.
-- Aborts with a timeout reason when none appears within
-- 'defaultAwaitBudgetUs'.
botSendsDocument :: StepDef TelegramTestScript c (ScenarioState app) a
botSendsDocument =
    thenDef "the bot sends a document" $ \_params ->
        awaitMatching "a document reply" isDocumentObs

--------------------------------------------------------------------------------
-- The canonical bootstrap
--------------------------------------------------------------------------------

-- | The canonical @tgTest@-shaped 'ScenarioBootstrap': the executor it builds
-- runs the BDD scenario's step program as a 'tgTestWithMocks' dialog over the
-- runner-owned mocks, so a @gherkinSpec@ scenario IS a @tgTest@ run.
--
-- PRE-CONTRACT: must be called where hspec expectations are legal — executors
-- always run inside an @it@, and a failed step run is reported through
-- 'expectationFailure'. @baseCfg@ must satisfy the 'tgTestWithMocks' config
-- requirement (@ttgPerformerConfig@ with @tcTelegram@ = @Mocked@, as in
-- 'LazyCircus.Testing.TgTest.defaultTgTestConfig').
-- POST-CONTRACT: the step program runs on the supplied runner-owned mocks via
-- 'tgTestWithMocks' with @tcJournal = Just journal@ wired into the performer
-- config, so Given-staging performed on those mocks is visible to the bot and
-- the journal collects the bot's outputs for Then-observations. The run's
-- mailboxes are discarded; a 'LazyCircus.Testing.TgTest.TgTestError' fails the
-- enclosing example with its 'tgeDescription' (the fallback outcome is
-- unreachable after 'expectationFailure').
tgTestBootstrap
    :: TgTestConfig app
    -- ^ run-level @tgTest@ config (the fresh journal is injected per scenario)
    -> (TestConfig app -> Mocks serviceLib -> IO (Update -> IO ()))
    -- ^ the app's update driver, wired to the config and mocks of this run
    -> ScenarioBootstrap serviceLib app TelegramTestScript
tgTestBootstrap baseCfg buildAction journal mocks =
    pure $ \stepProgram -> do
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
                expectationFailure (T.unpack (tgeDescription err))
                pure (error "unreachable after expectationFailure")

--------------------------------------------------------------------------------
-- Await machinery
--------------------------------------------------------------------------------

-- | One selective wait threaded through the scenario state: awaits the next
-- unconsumed observation satisfying the predicate (folded into the dialog
-- state inside 'awaitObservation') and emits nothing.
-- POST-CONTRACT: On success exactly one observation has been consumed. On
-- timeout the DSL aborts with the rendered 'AwaitTimeout'; nothing was
-- consumed.
awaitMatching ::
    Text ->
    (Observation app -> Bool) ->
    ScenarioState app ->
    TelegramTestScript (ScenarioState app, Maybe a)
awaitMatching awaitDesc predicate st = do
    result <- liftIO (awaitObservation defaultAwaitBudgetUs st predicate awaitDesc)
    case result of
        Right (_, st') -> pure (st', Nothing)
        Left timedOut -> guardWith (renderTimeout timedOut) False >> pure (st, Nothing)

-- | Renders an 'AwaitTimeout' as a step-failure reason.
renderTimeout :: AwaitTimeout -> Text
renderTimeout err =
    "timed out after " <> tshow (awaitTimeoutBudgetUs err)
        <> "us waiting for " <> awaitTimeoutAwaited err

-- | Failure message when the last reply lacks the expected fragment.
missingFragment :: Text -> Text -> Text
missingFragment fragment txt =
    "the last reply " <> tshow txt <> " does not contain " <> tshow fragment

--------------------------------------------------------------------------------
-- Predicates (core ObsTg* only, never ObsApp)
--------------------------------------------------------------------------------

-- | Predicate: a bot text message replying with exactly the given text.
isReplyWithText :: Text -> Observation app -> Bool
isReplyWithText expected obs = case obs of
    ObsTgMessage{obsText = txt} -> txt == expected
    _ -> False

-- | Predicate: a bot text message carrying reply markup.
isKeyboardReply :: Observation app -> Bool
isKeyboardReply obs = case obs of
    ObsTgMessage{obsMarkup = markup} -> isJust markup
    _ -> False

-- | Predicate: a reaction the bot set.
isReactionObs :: Observation app -> Bool
isReactionObs ObsTgReaction{} = True
isReactionObs _ = False

-- | Predicate: a message deletion.
isDeleteObs :: Observation app -> Bool
isDeleteObs ObsTgDelete{} = True
isDeleteObs _ = False

-- | Predicate: a document the bot sent.
isDocumentObs :: Observation app -> Bool
isDocumentObs ObsTgDocument{} = True
isDocumentObs _ = False
