{-# LANGUAGE NoImplicitPrelude #-}

{- | Library @When@- and @Then@-phase step constructors for the Telegram
dialog subset of the BDD runner — the shared step vocabulary every app
registry can reuse.

The constructors are registry-ready 'StepDef's over the canonical stack: the
dialog monad is 'TelegramTestScript' (the @tgTest@ DSL — a parameter-free
reader over the test runtime with an IO escape), and the threaded state is
'ScenarioState' (the observation journal's consumed set plus the derived
dialog view). @Then@ constructors build 'thenDef' entries, @When@
constructors ('userSends', 'memberTakesStage', 'defaultUserTakesStage',
'userVotesFor', 'userVotesIn', 'memberVotesFor', 'memberVotesIn') build
'whenDef' entries, so
document steps — including @And@\/@But@ continuations, which inherit the
previous step's keyword during parsing — select them. The expected values are
read from the step text's captured parameters themselves (via
'LazyCircus.Testing.Bdd.Pattern.lookupParam') and from the step's @| ... |@
argument table (via 'LazyCircus.Testing.Bdd.Pattern.StepParams'
@stepParamsTable@), not passed at registration time.

Acting user: the user-named input steps ('userSends', 'userVotesFor',
'userVotesIn') act as the CURRENT actor — the state's 'actingUserId', i.e.
the 'LazyCircus.Testing.Updates.defaultTestUserId' until a takes-the-stage
step ('memberTakesStage' \/ 'defaultUserTakesStage') puts a cast member on
stage (the state's 'ssActingUser' field; it survives every 'awaitObservation'
and resets per scenario). The member-named steps ('memberVotesFor'\/
'memberVotesIn') are explicit shorthands: they always act as the login named
in their own capture, resolved through
'LazyCircus.Testing.Updates.userIdForLogin', regardless of the current actor.

Await semantics (one await = one observation): every @Then@ constructor
except 'botReplyContains', 'pollIsPublic', 'pollIsAnonymous', the poll
choice-flag sextet ('pollAllowsMultipleAnswers', 'pollIsSingleChoice',
'pollAllowsRevote', 'pollForbidsRevote', 'pollOptionsAreShuffled',
'pollOptionsAreNotShuffled') and
'reactionIsBig' performs ONE
'awaitObservation' whose predicate
matches ONLY the core @ObsTg*@ constructors — app-specific 'ObsApp' entries
are skipped over and never consumed. A matched 'ObsTgMessage' folds into
'ssDialog' ('dsLastReply' from the text, 'dsLastKeyboard' from its markup),
a matched 'ObsTgPoll' folds its 'PollDigest' into 'dsLastPoll' (what the vote
steps 'userVotesFor'\/'userVotesIn'\/'memberVotesFor'\/'memberVotesIn' vote
against — the @user@ pair as the current actor ('actingUserId'), the
@member@ pair as the cast member named in the step's @«@login@»@ capture,
resolved through 'LazyCircus.Testing.Updates.userIdForLogin'), and a matched
'ObsTgReaction' folds its 'ReactionDigest' into 'dsLastReaction' (the target
id, the projected emoji texts and the big-animation flag).
'botReplyContains' is the
And-continuation: it re-inspects the last consumed entry via
'peekLastConsumed' — NO wait and NO consumption — asserting on @dsLastReply@
without moving the cursor. The publicness pair 'pollIsPublic' and
'pollIsAnonymous' are fellow And-continuations asserting on the last consumed
poll's digest ('dsLastPoll') — likewise with NO wait and NO consumption; so
is 'reactionIsBig' on the last consumed reaction's digest ('dsLastReaction'),
and so is the poll choice-flag sextet ('pollAllowsMultipleAnswers',
'pollIsSingleChoice', 'pollAllowsRevote', 'pollForbidsRevote',
'pollOptionsAreShuffled', 'pollOptionsAreNotShuffled') on the last consumed
poll's digest — each demanding its flag was set EXPLICITLY in the send
request (an unset flag aborts with the server-default explanation).

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
    , botSendsPoll
    , pollIsPublic
    , pollIsAnonymous
    , pollAllowsMultipleAnswers
    , pollIsSingleChoice
    , pollAllowsRevote
    , pollForbidsRevote
    , pollOptionsAreShuffled
    , pollOptionsAreNotShuffled
    , botReactsTo
    , botReactsWith
    , reactionIsBig
    , botDeletesMessage
    , botSendsDocument
    , userSends
    , memberTakesStage
    , defaultUserTakesStage
    , userVotesFor
    , userVotesIn
    , memberVotesFor
    , memberVotesIn
    , tgTestBootstrap
    ) where

import RIO
import RIO.Text qualified as T

import LazyCircus.Testing.Bdd.Journal
    ( AwaitTimeout (..)
    , DialogState (..)
    , Observation (..)
    , PollDigest (..)
    , ReactionDigest (..)
    , ScenarioState (..)
    , Sequenced (..)
    , actingUserId
    , awaitObservation
    , defaultAwaitBudgetUs
    , peekLastConsumed
    , reactionEmojiTexts
    )
import LazyCircus.Testing.Bdd.Pattern (StepParams (..), lookupParam)
import LazyCircus.Testing.Bdd.Runner (ScenarioBootstrap)
import LazyCircus.Testing.Bdd.Step (StepDef (..), thenDef, whenDef)
import LazyCircus.Testing.Performer (Mocks, TestConfig (..))
import LazyCircus.Testing.TgTest
    ( TelegramTestScript
    , TgTestConfig (..)
    , guardWith
    , sendPollAnswerByUser
    , sendMessageByUser
    , tgeDescription
    , tgTestWithMocks
    )
import LazyCircus.Testing.Updates (defaultTestChatId, userIdForLogin)
import Telegram.Bot.API (Update, UserId)
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

-- | @the bot sends a poll "$question"@ — the bot sent a poll whose question
-- equals the step's quoted capture; a @| ... |@ table attached to the step
-- pins the full option list (one option per single-cell row).
--
-- PRE-CONTRACT: The expected question appears inside double quotes in the
-- step text (the pattern's @"$question"@ span) — the runner matched the step,
-- so the capture is present. When a table is attached, every row must carry
-- exactly one cell (checked BEFORE any waiting — the step aborts with an
-- explanatory reason otherwise).
-- POST-CONTRACT: On success exactly one 'ObsTgPoll' with the expected
-- question (and, when the table pinned the options, exactly those option
-- texts in order) has been consumed and folded into 'ssDialog' as
-- 'dsLastPoll' — a subsequent vote step ('userVotesFor', 'userVotesIn',
-- 'memberVotesFor', 'memberVotesIn') resolves against it. When no unconsumed
-- matching poll appears within 'defaultAwaitBudgetUs',
-- the step aborts with a timeout reason and nothing is consumed.
botSendsPoll :: StepDef TelegramTestScript c (ScenarioState app) a
botSendsPoll =
    thenDef "the bot sends a poll \"$question\"" $ \params st ->
        case tableOptions (stepParamsTable params) of
            Left problem -> guardWith problem False >> pure (st, Nothing)
            Right mExpected -> do
                let question = fromMaybe "" (lookupParam "$question" params)
                awaitMatching ("a poll \"" <> question <> "\"") (isPollWith question mExpected) st

-- | @the poll is public@ — And-continuation asserting the last consumed poll
-- was sent as PUBLIC: the request set @is_anonymous@ to 'False' explicitly.
--
-- The Telegram server delivers @poll_answer@ updates only for public polls
-- and defaults @is_anonymous@ to @True@ when the request leaves it unset, so
-- a forgotten flag means empty vote data in production while the mock stays
-- green — this step catches exactly that (the mock does not simulate the
-- server-side default; the step checks the request's flag, which is what the
-- app controls).
--
-- PRE-CONTRACT: A poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise.
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not. The poll counts as public only when the digest's 'pdIsAnonymous' is
-- @Just False@ — a @Nothing@ (request left the flag unset) or @Just True@
-- aborts the DSL with a guard failure explaining the server default.
pollIsPublic :: StepDef TelegramTestScript c (ScenarioState app) a
pollIsPublic =
    thenDef "the poll is public" $ \_params st ->
        case dsLastPoll (ssDialog st) of
            Nothing ->
                guardWith noPollYetReason False
                    >> pure (st, Nothing)
            Just digest -> do
                guardWith (notPublicReason digest) (pdIsAnonymous digest == Just False)
                pure (st, Nothing)

-- | Guard-failure message when the consumed poll is not public: covers an
-- explicitly anonymous request and the unset-flag trap alike (the server
-- defaults anonymous polls to @True@).
notPublicReason :: PollDigest -> Text
notPublicReason digest = case pdIsAnonymous digest of
    Nothing ->
        "the poll \"" <> pdQuestion digest
            <> "\" left is_anonymous unset in the send request; the Telegram server defaults"
            <> " it to anonymous, so the poll is NOT public — set sendPollIsAnonymous = Just False"
            <> " to make it public (only public polls deliver poll_answer)"
    Just True ->
        "the poll \"" <> pdQuestion digest
            <> "\" was sent with is_anonymous = True (an anonymous poll)"

-- | @the poll is anonymous@ — And-continuation asserting the last consumed
-- poll was sent as ANONYMOUS: the request set @is_anonymous@ to 'True'
-- explicitly. The strict sibling of 'pollIsPublic'.
--
-- PRE-CONTRACT: A poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise.
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not. The poll counts as anonymous only when the digest's 'pdIsAnonymous'
-- is @Just True@ — a @Nothing@ (request left the flag unset) aborts with the
-- explanation that the app never said so explicitly, even though the server
-- would treat the poll as anonymous by default.
pollIsAnonymous :: StepDef TelegramTestScript c (ScenarioState app) a
pollIsAnonymous =
    thenDef "the poll is anonymous" $ \_params st ->
        case dsLastPoll (ssDialog st) of
            Nothing ->
                guardWith noPollYetReason False
                    >> pure (st, Nothing)
            Just digest -> do
                guardWith (notAnonymousReason digest) (pdIsAnonymous digest == Just True)
                pure (st, Nothing)

-- | Guard-failure message when the consumed poll is not explicitly anonymous.
notAnonymousReason :: PollDigest -> Text
notAnonymousReason digest = case pdIsAnonymous digest of
    Nothing ->
        "the poll \"" <> pdQuestion digest
            <> "\" left is_anonymous unset in the send request; the server would treat it as"
            <> " anonymous by default, but the step requires the explicit sendPollIsAnonymous = Just True"
    Just False ->
        "the poll \"" <> pdQuestion digest
            <> "\" was sent with is_anonymous = False (a public poll)"

-- | @the poll allows multiple answers@ — And-continuation asserting the last
-- consumed poll was sent as MULTIPLE-CHOICE: the request set
-- @allows_multiple_answers@ to 'True' explicitly.
--
-- The Telegram server defaults @allows_multiple_answers@ to @False@ when the
-- request leaves it unset, so a forgotten flag means a single-choice poll in
-- production — this step catches exactly that (the mock does not simulate the
-- server-side default; the step checks the request's flag, which is what the
-- app controls).
--
-- PRE-CONTRACT: A poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise.
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not. The poll counts as multiple-choice only when the digest's
-- 'pdAllowsMultipleAnswers' is @Just True@ — a @Nothing@ (request left the
-- flag unset) or @Just False@ aborts the DSL with a guard failure explaining
-- the server default.
pollAllowsMultipleAnswers :: StepDef TelegramTestScript c (ScenarioState app) a
pollAllowsMultipleAnswers =
    thenDef "the poll allows multiple answers" $ \_params st ->
        case dsLastPoll (ssDialog st) of
            Nothing ->
                guardWith noPollYetReason False
                    >> pure (st, Nothing)
            Just digest -> do
                guardWith (notMultipleAnswersReason digest) (pdAllowsMultipleAnswers digest == Just True)
                pure (st, Nothing)

-- | Guard-failure message when the consumed poll is not explicitly
-- multiple-choice (the server defaults @allows_multiple_answers@ to @False@).
notMultipleAnswersReason :: PollDigest -> Text
notMultipleAnswersReason digest = case pdAllowsMultipleAnswers digest of
    Nothing ->
        "the poll \"" <> pdQuestion digest
            <> "\" left allows_multiple_answers unset in the send request; the Telegram server"
            <> " defaults it to False (a single-choice poll), so set sendPollAllowsMultipleAnswers"
            <> " = Just True to allow multiple answers"
    Just False ->
        "the poll \"" <> pdQuestion digest
            <> "\" was sent with allows_multiple_answers = False (a single-choice poll)"

-- | @the poll is single choice@ — And-continuation asserting the last
-- consumed poll was sent as SINGLE-CHOICE: the request set
-- @allows_multiple_answers@ to 'False' explicitly. The strict sibling of
-- 'pollAllowsMultipleAnswers'.
--
-- PRE-CONTRACT: A poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise.
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not. The poll counts as single-choice only when the digest's
-- 'pdAllowsMultipleAnswers' is @Just False@ — a @Nothing@ (request left the
-- flag unset) aborts with the explanation that the app never said so
-- explicitly, even though the server would treat the poll as single-choice by
-- default.
pollIsSingleChoice :: StepDef TelegramTestScript c (ScenarioState app) a
pollIsSingleChoice =
    thenDef "the poll is single choice" $ \_params st ->
        case dsLastPoll (ssDialog st) of
            Nothing ->
                guardWith noPollYetReason False
                    >> pure (st, Nothing)
            Just digest -> do
                guardWith (notSingleChoiceReason digest) (pdAllowsMultipleAnswers digest == Just False)
                pure (st, Nothing)

-- | Guard-failure message when the consumed poll is not explicitly
-- single-choice.
notSingleChoiceReason :: PollDigest -> Text
notSingleChoiceReason digest = case pdAllowsMultipleAnswers digest of
    Nothing ->
        "the poll \"" <> pdQuestion digest
            <> "\" left allows_multiple_answers unset in the send request; the server would treat"
            <> " it as single-choice by default, but the step requires the explicit"
            <> " sendPollAllowsMultipleAnswers = Just False"
    Just True ->
        "the poll \"" <> pdQuestion digest
            <> "\" was sent with allows_multiple_answers = True (a multiple-choice poll)"

-- | @the poll allows re-voting@ — And-continuation asserting the last
-- consumed poll was sent as REVOTABLE: the request set @allows_revoting@ to
-- 'True' explicitly.
--
-- The Telegram server defaults @allows_revoting@ BY POLL TYPE when the
-- request leaves it unset (@False@ for quizzes, @True@ for regular polls), so
-- a forgotten flag means the re-vote behaviour silently follows the poll
-- type — this step demands the app said @True@ on purpose.
--
-- PRE-CONTRACT: A poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise.
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not. The poll counts as revotable only when the digest's
-- 'pdAllowsRevoting' is @Just True@ — a @Nothing@ (request left the flag
-- unset) or @Just False@ aborts the DSL with a guard failure explaining the
-- type-dependent server default.
pollAllowsRevote :: StepDef TelegramTestScript c (ScenarioState app) a
pollAllowsRevote =
    thenDef "the poll allows re-voting" $ \_params st ->
        case dsLastPoll (ssDialog st) of
            Nothing ->
                guardWith noPollYetReason False
                    >> pure (st, Nothing)
            Just digest -> do
                guardWith (notRevotableReason digest) (pdAllowsRevoting digest == Just True)
                pure (st, Nothing)

-- | Guard-failure message when the consumed poll is not explicitly revotable
-- (the server defaults @allows_revoting@ by poll type: @False@ for quizzes,
-- @True@ for regular polls).
notRevotableReason :: PollDigest -> Text
notRevotableReason digest = case pdAllowsRevoting digest of
    Nothing ->
        "the poll \"" <> pdQuestion digest
            <> "\" left allows_revoting unset in the send request; the Telegram server defaults"
            <> " it by poll type (False for quizzes, True for regular polls), so set"
            <> " sendPollAllowsRevoting = Just True to allow re-voting explicitly"
    Just False ->
        "the poll \"" <> pdQuestion digest
            <> "\" was sent with allows_revoting = False (re-voting forbidden)"

-- | @the poll does not allow re-voting@ — And-continuation asserting the last
-- consumed poll was sent with re-voting FORBIDDEN: the request set
-- @allows_revoting@ to 'False' explicitly. The strict sibling of
-- 'pollAllowsRevote'.
--
-- PRE-CONTRACT: A poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise.
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not. The poll counts as non-revotable only when the digest's
-- 'pdAllowsRevoting' is @Just False@ — a @Nothing@ (request left the flag
-- unset) aborts with the explanation that the app never said so explicitly,
-- even though the server would default the flag by poll type.
pollForbidsRevote :: StepDef TelegramTestScript c (ScenarioState app) a
pollForbidsRevote =
    thenDef "the poll does not allow re-voting" $ \_params st ->
        case dsLastPoll (ssDialog st) of
            Nothing ->
                guardWith noPollYetReason False
                    >> pure (st, Nothing)
            Just digest -> do
                guardWith (notForbiddenRevoteReason digest) (pdAllowsRevoting digest == Just False)
                pure (st, Nothing)

-- | Guard-failure message when the consumed poll does not explicitly forbid
-- re-voting.
notForbiddenRevoteReason :: PollDigest -> Text
notForbiddenRevoteReason digest = case pdAllowsRevoting digest of
    Nothing ->
        "the poll \"" <> pdQuestion digest
            <> "\" left allows_revoting unset in the send request; the server would default it"
            <> " by poll type (False for quizzes, True for regular polls), but the step requires"
            <> " the explicit sendPollAllowsRevoting = Just False"
    Just True ->
        "the poll \"" <> pdQuestion digest
            <> "\" was sent with allows_revoting = True (re-voting allowed)"

-- | @the poll options are shuffled@ — And-continuation asserting the last
-- consumed poll asked Telegram to SHUFFLE its options: the request set
-- @shuffle_options@ to 'True' explicitly.
--
-- Shuffling is SERVER-SIDE: the mock (and the sent option list) keep the
-- request order — Telegram randomises the order shown to each viewer. The
-- step observes the request's flag, which is what the app controls; the
-- order-sensitive pin of the option texts stays with 'botSendsPoll'.
--
-- PRE-CONTRACT: A poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise.
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not. The poll counts as shuffled only when the digest's
-- 'pdShuffleOptions' is @Just True@ — a @Nothing@ (request left the flag
-- unset) or @Just False@ aborts the DSL with a guard failure explaining the
-- server default (options shown in the sent order).
pollOptionsAreShuffled :: StepDef TelegramTestScript c (ScenarioState app) a
pollOptionsAreShuffled =
    thenDef "the poll options are shuffled" $ \_params st ->
        case dsLastPoll (ssDialog st) of
            Nothing ->
                guardWith noPollYetReason False
                    >> pure (st, Nothing)
            Just digest -> do
                guardWith (notShuffledReason digest) (pdShuffleOptions digest == Just True)
                pure (st, Nothing)

-- | Guard-failure message when the consumed poll does not explicitly ask for
-- shuffled options (the server then shows the options in the sent order).
notShuffledReason :: PollDigest -> Text
notShuffledReason digest = case pdShuffleOptions digest of
    Nothing ->
        "the poll \"" <> pdQuestion digest
            <> "\" left shuffle_options unset in the send request; the Telegram server then shows"
            <> " the options in the order they were sent, so set sendPollShuffleOptions = Just True"
            <> " to shuffle them"
    Just False ->
        "the poll \"" <> pdQuestion digest
            <> "\" was sent with shuffle_options = False (options in the sent order)"

-- | @the poll options are not shuffled@ — And-continuation asserting the last
-- consumed poll was sent WITHOUT option shuffling: the request set
-- @shuffle_options@ to 'False' explicitly. The strict sibling of
-- 'pollOptionsAreShuffled'.
--
-- PRE-CONTRACT: A poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise.
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not. The poll counts as unshuffled only when the digest's
-- 'pdShuffleOptions' is @Just False@ — a @Nothing@ (request left the flag
-- unset) aborts with the explanation that the app never said so explicitly,
-- even though the server would show the options in the sent order anyway.
pollOptionsAreNotShuffled :: StepDef TelegramTestScript c (ScenarioState app) a
pollOptionsAreNotShuffled =
    thenDef "the poll options are not shuffled" $ \_params st ->
        case dsLastPoll (ssDialog st) of
            Nothing ->
                guardWith noPollYetReason False
                    >> pure (st, Nothing)
            Just digest -> do
                guardWith (notUnshuffledReason digest) (pdShuffleOptions digest == Just False)
                pure (st, Nothing)

-- | Guard-failure message when the consumed poll does not explicitly pin the
-- unshuffled option order.
notUnshuffledReason :: PollDigest -> Text
notUnshuffledReason digest = case pdShuffleOptions digest of
    Nothing ->
        "the poll \"" <> pdQuestion digest
            <> "\" left shuffle_options unset in the send request; the server would show the"
            <> " options in the sent order, but the step requires the explicit"
            <> " sendPollShuffleOptions = Just False"
    Just True ->
        "the poll \"" <> pdQuestion digest
            <> "\" was sent with shuffle_options = True (options shuffled for each viewer)"

-- | @the user sends "$msg"@ — the CURRENT actor sends a text message in the
-- default test chat. The canonical user-input step: \"the user\" always means
-- the state's 'actingUserId' ('defaultTestUserId' until a 'memberTakesStage'
-- step puts a cast member on stage).
--
-- PRE-CONTRACT: The message text appears inside double quotes in the step
-- text (the pattern's @"$msg"@ span) — the runner matched the step, so the
-- capture is present.
-- POST-CONTRACT: One text-message update has been fed to the bot from
-- 'actingUserId' of the threaded state in 'defaultTestChatId'; the scenario
-- state passes through unchanged.
userSends :: StepDef TelegramTestScript c (ScenarioState app) a
userSends =
    whenDef "the user sends \"$msg\"" $ \params st -> do
        let msg = fromMaybe "" (lookupParam "$msg" params)
        _ <- sendMessageByUser (actingUserId st) defaultTestChatId msg
        pure (st, Nothing)

-- | @the member "$login" takes the stage@ — every subsequent user-named input
-- step acts as the named cast member (resolved through
-- 'LazyCircus.Testing.Updates.userIdForLogin'). The multi-actor switch: one
-- step changes WHO \"the user\" is, so every input verb stays single-form
-- instead of sprouting @member<Verb>@ variants.
--
-- PRE-CONTRACT: The login (verbatim, typically with its leading @@@) appears
-- inside double quotes in the step text (the pattern's @"$login"@ span) — the
-- runner matched the step, so the capture is present.
-- POST-CONTRACT: 'ssActingUser' of the threaded state is set to the member's
-- id — 'userSends'\/'userVotesFor'\/'userVotesIn' (and any spec-local step
-- reading 'actingUserId') act as that member until 'defaultUserTakesStage'
-- resets it or the scenario ends (a fresh state starts with 'Nothing').
memberTakesStage :: StepDef TelegramTestScript c (ScenarioState app) a
memberTakesStage =
    whenDef "the member \"$login\" takes the stage" $ \params st -> do
        let login = fromMaybe "" (lookupParam "$login" params)
        pure (st{ssActingUser = Just (userIdForLogin login)}, Nothing)

-- | @the default user takes the stage@ — resets the acting user to the
-- 'defaultTestUserId' (clears 'ssActingUser'), undoing a previous
-- 'memberTakesStage'.
--
-- PRE-CONTRACT: None.
-- POST-CONTRACT: 'ssActingUser' of the threaded state is 'Nothing' —
-- user-named input steps act as the default test user again; the state
-- passes through otherwise unchanged.
defaultUserTakesStage :: StepDef TelegramTestScript c (ScenarioState app) a
defaultUserTakesStage =
    whenDef "the default user takes the stage" $ \_params st ->
        pure (st{ssActingUser = Nothing}, Nothing)

-- | @the user votes for "$option" in the poll@ — the CURRENT actor votes for
-- exactly the step's quoted capture in the last consumed poll.
--
-- PRE-CONTRACT: The option text appears inside double quotes in the step text
-- (the pattern's @"$option"@ span) — the runner matched the step, so the
-- capture is present. A poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise. A table attached to this step is a misuse
-- ('userVotesIn' owns the table form) and aborts likewise.
-- POST-CONTRACT: On success one chat-less @poll_answer@ update has been fed
-- to the bot against the consumed poll's id ('pdPollId') from 'actingUserId'
-- of the threaded state, carrying the single option index the capture
-- resolves to in 'pdOptions'; the scenario state passes through unchanged. On
-- an unknown option text the DSL aborts with a guard failure and nothing is
-- fed.
userVotesFor :: StepDef TelegramTestScript c (ScenarioState app) a
userVotesFor =
    whenDef "the user votes for \"$option\" in the poll" $ \params st ->
        case (stepParamsTable params, dsLastPoll (ssDialog st)) of
            (Just _, _) ->
                guardWith "a table is attached to the vote step; use 'the user votes in the poll' with the options table instead" False
                    >> pure (st, Nothing)
            (Nothing, Nothing) ->
                guardWith noPollYetReason False
                    >> pure (st, Nothing)
            (Nothing, Just digest) -> do
                let option = fromMaybe "" (lookupParam "$option" params)
                voteInAs (actingUserId st) digest [option] st

-- | @the user votes in the poll@ — the user votes for the option texts of the
-- @| ... |@ table attached to the step (one single-cell row per option), in
-- the last consumed poll. The multi-vote form of 'userVotesFor' (a
-- multi-answer poll votes with all the rows' indexes at once).
--
-- PRE-CONTRACT: A table with one single-cell row per voted option is attached
-- to the step, and a poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise.
-- POST-CONTRACT: On success one chat-less @poll_answer@ update has been fed
-- to the bot against the consumed poll's id ('pdPollId') from 'actingUserId'
-- of the threaded state, carrying the option indexes the table rows resolve
-- to in 'pdOptions', in table order; the scenario state passes through
-- unchanged. On an unknown option text the DSL aborts with a guard failure
-- and nothing is fed.
userVotesIn :: StepDef TelegramTestScript c (ScenarioState app) a
userVotesIn =
    whenDef "the user votes in the poll" $ \params st ->
        case (dsLastPoll (ssDialog st), tableOptions (stepParamsTable params)) of
            (_, Left problem) ->
                guardWith problem False
                    >> pure (st, Nothing)
            (_, Right Nothing) ->
                guardWith "attach the options table (one single-cell row per option) to 'the user votes in the poll'" False
                    >> pure (st, Nothing)
            (Nothing, Right (Just _)) ->
                guardWith noPollYetReason False
                    >> pure (st, Nothing)
            (Just digest, Right (Just options)) ->
                voteInAs (actingUserId st) digest options st

-- | @the member "$login" votes for "$option" in the poll@ — a named cast
-- member (NOT the default test user) votes for exactly the step's quoted
-- capture in the last consumed poll. The multi-actor form of 'userVotesFor':
-- the member vote arrives at the bot as its own @poll_answer@ update carrying
-- the member's user id, so scenarios covering several participants are
-- distinguishable bot-side.
--
-- PRE-CONTRACT: The login (verbatim, typically with its leading @@@) and the
-- option text appear inside double quotes in the step text (the pattern's
-- @"$login"@ and @"$option"@ spans) — the runner matched the step, so the
-- captures are present. A poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise. A table attached to this step is a misuse
-- ('memberVotesIn' owns the table form) and aborts likewise.
-- POST-CONTRACT: On success one chat-less @poll_answer@ update has been fed
-- to the bot against the consumed poll's id ('pdPollId') from user id
-- 'LazyCircus.Testing.Updates.userIdForLogin' of the captured login, carrying
-- the single option index the capture resolves to in 'pdOptions'; the
-- scenario state passes through unchanged. On an unknown option text the DSL
-- aborts with a guard failure and nothing is fed.
memberVotesFor :: StepDef TelegramTestScript c (ScenarioState app) a
memberVotesFor =
    whenDef "the member \"$login\" votes for \"$option\" in the poll" $ \params st ->
        case (stepParamsTable params, dsLastPoll (ssDialog st)) of
            (Just _, _) ->
                guardWith "a table is attached to the member vote step; use 'the member \"$login\" votes in the poll' with the options table instead" False
                    >> pure (st, Nothing)
            (Nothing, Nothing) ->
                guardWith noPollYetReason False
                    >> pure (st, Nothing)
            (Nothing, Just digest) -> do
                let login = fromMaybe "" (lookupParam "$login" params)
                    option = fromMaybe "" (lookupParam "$option" params)
                voteInAs (userIdForLogin login) digest [option] st

-- | @the member "$login" votes in the poll@ — a named cast member (NOT the
-- default test user) votes for the option texts of the @| ... |@ table
-- attached to the step (one single-cell row per option), in the last consumed
-- poll. The multi-actor, multi-vote form of 'userVotesIn' (a multi-answer
-- poll votes with all the rows' indexes at once).
--
-- PRE-CONTRACT: The login (verbatim, typically with its leading @@@) appears
-- inside double quotes in the step text (the pattern's @"$login"@ span), a
-- table with one single-cell row per voted option is attached to the step,
-- and a poll has been consumed by a previous step (e.g. 'botSendsPoll'), so
-- 'dsLastPoll' holds its digest — the step aborts with an explanatory reason
-- otherwise.
-- POST-CONTRACT: On success one chat-less @poll_answer@ update has been fed
-- to the bot against the consumed poll's id ('pdPollId') from user id
-- 'LazyCircus.Testing.Updates.userIdForLogin' of the captured login, carrying
-- the option indexes the table rows resolve to in 'pdOptions', in table
-- order; the scenario state passes through unchanged. On an unknown option
-- text the DSL aborts with a guard failure and nothing is fed.
memberVotesIn :: StepDef TelegramTestScript c (ScenarioState app) a
memberVotesIn =
    whenDef "the member \"$login\" votes in the poll" $ \params st ->
        case (dsLastPoll (ssDialog st), tableOptions (stepParamsTable params)) of
            (_, Left problem) ->
                guardWith problem False
                    >> pure (st, Nothing)
            (_, Right Nothing) ->
                guardWith "attach the options table (one single-cell row per option) to 'the member \"$login\" votes in the poll'" False
                    >> pure (st, Nothing)
            (Nothing, Right (Just _)) ->
                guardWith noPollYetReason False
                    >> pure (st, Nothing)
            (Just digest, Right (Just options)) -> do
                let login = fromMaybe "" (lookupParam "$login" params)
                voteInAs (userIdForLogin login) digest options st

-- | @the bot reacts to a message@ — the bot set a reaction (on any message).
--
-- PRE-CONTRACT: None.
-- POST-CONTRACT: On success exactly one 'ObsTgReaction' has been consumed;
-- the reaction digest is folded into 'dsLastReaction' (the target id, the
-- projected emoji texts and the big flag). Aborts with a timeout reason when
-- none appears within 'defaultAwaitBudgetUs'.
botReactsTo :: StepDef TelegramTestScript c (ScenarioState app) a
botReactsTo =
    thenDef "the bot reacts to a message" $ \_params ->
        awaitMatching "a message reaction" isReactionObs

-- | @the bot reacts with "$emoji"@ — the bot set a reaction whose payload
-- contains the step's quoted emoji capture. The emoji is matched against the
-- payload projection ('reactionEmojiTexts'), so the same step matches emoji
-- and custom-emoji reactions alike.
--
-- PRE-CONTRACT: The expected emoji appears inside double quotes in the step
-- text (the pattern's @"$emoji"@ span) — the runner matched the step, so the
-- capture is present.
-- POST-CONTRACT: On success exactly one 'ObsTgReaction' carrying the emoji
-- has been consumed and folded into 'ssDialog' as 'dsLastReaction' — the
-- 'reactionIsBig' continuation asserts against it. When no unconsumed
-- matching reaction appears within 'defaultAwaitBudgetUs', the step aborts
-- with a timeout reason and nothing is consumed.
botReactsWith :: StepDef TelegramTestScript c (ScenarioState app) a
botReactsWith =
    thenDef "the bot reacts with \"$emoji\"" $ \params st -> do
        let emoji = fromMaybe "" (lookupParam "$emoji" params)
        awaitMatching ("a \"" <> emoji <> "\" reaction") (isReactionWith emoji) st

-- | @the reaction is big@ — And-continuation asserting the last consumed
-- reaction was sent as a BIG animation: the request set @is_big@ to 'True'
-- explicitly.
--
-- PRE-CONTRACT: A reaction has been consumed by a previous step (e.g.
-- 'botReactsWith'), so 'dsLastReaction' holds its digest — the step aborts
-- with an explanatory reason otherwise.
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not. The reaction counts as big only when the digest's 'rdIsBig' is
-- @Just True@ — a @Nothing@ (request left the flag unset) or @Just False@
-- aborts the DSL with a guard failure.
reactionIsBig :: StepDef TelegramTestScript c (ScenarioState app) a
reactionIsBig =
    thenDef "the reaction is big" $ \_params st ->
        case dsLastReaction (ssDialog st) of
            Nothing ->
                guardWith noReactionYetReason False
                    >> pure (st, Nothing)
            Just digest -> do
                guardWith (notBigReason digest) (rdIsBig digest == Just True)
                pure (st, Nothing)

-- | Guard-failure message when the And-continuation runs before any reaction
-- was consumed.
noReactionYetReason :: Text
noReactionYetReason =
    "no reaction has been consumed yet; a reaction-consuming step (e.g. 'the bot reacts with ...') must run first"

-- | Guard-failure message when the consumed reaction is not big: covers an
-- explicitly small animation and the unset-flag case alike.
notBigReason :: ReactionDigest -> Text
notBigReason digest = case rdIsBig digest of
    Nothing ->
        "the reaction on message " <> tshow (rdTargetMsgId digest)
            <> " left is_big unset in the send request; the step requires the explicit"
            <> " setMessageReactionRequestIsBig = Just True"
    Just False ->
        "the reaction on message " <> tshow (rdTargetMsgId digest)
            <> " was sent with is_big = False (a small animation)"

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

-- | Predicate: a reaction whose payload projection contains the given emoji
-- text (matches emoji and custom-emoji reactions alike).
isReactionWith :: Text -> Observation app -> Bool
isReactionWith emoji ObsTgReaction{obsReaction = reactions} =
    emoji `elem` maybe [] reactionEmojiTexts reactions
isReactionWith _ _ = False

-- | Predicate: a message deletion.
isDeleteObs :: Observation app -> Bool
isDeleteObs ObsTgDelete{} = True
isDeleteObs _ = False

-- | Predicate: a document the bot sent.
isDocumentObs :: Observation app -> Bool
isDocumentObs ObsTgDocument{} = True
isDocumentObs _ = False

-- | Predicate: a bot poll with the given question and — when the expected
-- options are pinned ('Just') — exactly those option texts in order.
isPollWith :: Text -> Maybe [Text] -> Observation app -> Bool
isPollWith question mExpectedOptions obs = case obs of
    ObsTgPoll{obsQuestion = q, obsOptions = options} ->
        q == question && maybe True (== options) mExpectedOptions
    _ -> False

-- | Extracts the expected poll options from a step table: 'Right Nothing'
-- when the step carries no table, 'Right' the single cell of every row (one
-- option per row) when it does, 'Left' an explanation when some row does not
-- have exactly one non-empty cell.
tableOptions :: Maybe [[Text]] -> Either Text (Maybe [Text])
tableOptions Nothing = Right Nothing
tableOptions (Just rows) = case traverse firstCell rows of
    Just cells -> Right (Just cells)
    Nothing -> Left (badPollTable rows)
  where
    -- | The row's single cell ('Nothing' unless the row is exactly one
    -- non-empty cell).
    firstCell [cell] | not (T.null cell) = Just cell
    firstCell _ = Nothing

-- | Guard-failure message for a poll table whose rows are not single cells.
badPollTable :: [[Text]] -> Text
badPollTable rows =
    "a poll option table must have exactly one non-empty cell per row (one option per row); got "
        <> tshow rows

-- | Guard-failure message for a vote step run before any poll was consumed.
noPollYetReason :: Text
noPollYetReason =
    "no poll has been consumed yet; a poll-consuming step (e.g. 'the bot sends a poll ...') must run first"

-- | Feeds one @poll_answer@ update for the consumed poll's digest from the
-- given user: resolves each voted option text to its index in the digest's
-- options (guard failure listing the poll's actual options on an unknown
-- text) and sends the ids — the engine behind every vote step
-- ('userVotesFor'\/'userVotesIn' pass the state's 'actingUserId', the member
-- pair passes the login's resolved id).
voteInAs :: UserId -> PollDigest -> [Text] -> ScenarioState app -> TelegramTestScript (ScenarioState app, Maybe a)
voteInAs userId digest voted st = case mapM (optionIndex (pdOptions digest)) voted of
    Nothing ->
        guardWith (unknownOptions digest voted) False
            >> pure (st, Nothing)
    Just optionIds -> do
        _ <- sendPollAnswerByUser userId (pdPollId digest) optionIds
        pure (st, Nothing)

-- | 0-based index of a text's first occurrence in the option list ('Nothing'
-- when absent).
optionIndex :: [Text] -> Text -> Maybe Int
optionIndex options option = lookup option (zip options [0 ..])

-- | Guard-failure message when a voted option text is not among the consumed
-- poll's options.
unknownOptions :: PollDigest -> [Text] -> Text
unknownOptions digest voted =
    "a vote step votes for an option the poll \"" <> pdQuestion digest
        <> "\" does not offer; poll options: " <> tshow (pdOptions digest)
        <> ", voted for: " <> tshow voted
