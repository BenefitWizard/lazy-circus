{-# LANGUAGE NoImplicitPrelude #-}

{- | Library @When@- and @Then@-phase step constructors for the Telegram
dialog subset of the BDD runner — the shared step vocabulary every app
registry can reuse.

The constructors are registry-ready 'StepDef's over the canonical stack: the
dialog monad is 'TelegramTestScript' (the @tgTest@ DSL — a parameter-free
reader over the test runtime with an IO escape), and the threaded state is
'ScenarioState' (the observation journal's consumed set plus the derived
dialog view). @Then@ constructors build 'thenDef' entries, @When@
constructors ('userVotesFor', 'userVotesIn', 'memberVotesFor',
'memberVotesIn') build 'whenDef' entries, so
document steps — including @And@\/@But@ continuations, which inherit the
previous step's keyword during parsing — select them. The expected values are
read from the step text's captured parameters themselves (via
'LazyCircus.Testing.Bdd.Pattern.lookupParam') and from the step's @| ... |@
argument table (via 'LazyCircus.Testing.Bdd.Pattern.StepParams'
@stepParamsTable@), not passed at registration time.

Await semantics (one await = one observation): every @Then@ constructor
except 'botReplyContains' performs ONE 'awaitObservation' whose predicate
matches ONLY the core @ObsTg*@ constructors — app-specific 'ObsApp' entries
are skipped over and never consumed. A matched 'ObsTgMessage' folds into
'ssDialog' ('dsLastReply' from the text, 'dsLastKeyboard' from its markup),
and a matched 'ObsTgPoll' folds its 'PollDigest' into 'dsLastPoll' (what the vote
steps 'userVotesFor'\/'userVotesIn'\/'memberVotesFor'\/'memberVotesIn' vote
against — the @user@ pair always as the default test user, the @member@ pair
as the cast member named in the step's @«@login@»@ capture, resolved through
'LazyCircus.Testing.Updates.userIdForLogin'). 'botReplyContains' is the
And-continuation: it re-inspects the last consumed entry via
'peekLastConsumed' — NO wait and NO consumption — asserting on @dsLastReply@
without moving the cursor.

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
    , botReactsTo
    , botDeletesMessage
    , botSendsDocument
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
    , ScenarioState (..)
    , Sequenced (..)
    , awaitObservation
    , defaultAwaitBudgetUs
    , peekLastConsumed
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
    , tgeDescription
    , tgTestWithMocks
    )
import LazyCircus.Testing.Updates (defaultTestUserId, userIdForLogin)
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

-- | @the user votes for "$option" in the poll@ — the user votes for exactly
-- the step's quoted capture in the last consumed poll.
--
-- PRE-CONTRACT: The option text appears inside double quotes in the step text
-- (the pattern's @"$option"@ span) — the runner matched the step, so the
-- capture is present. A poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise. A table attached to this step is a misuse
-- ('userVotesIn' owns the table form) and aborts likewise.
-- POST-CONTRACT: On success one chat-less @poll_answer@ update has been fed
-- to the bot against the consumed poll's id ('pdPollId'), carrying the single
-- option index the capture resolves to in 'pdOptions'; the scenario state
-- passes through unchanged. On an unknown option text the DSL aborts with a
-- guard failure and nothing is fed.
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
                voteIn digest [option] st

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
-- to the bot against the consumed poll's id ('pdPollId'), carrying the option
-- indexes the table rows resolve to in 'pdOptions', in table order; the
-- scenario state passes through unchanged. On an unknown option text the DSL
-- aborts with a guard failure and nothing is fed.
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
            (Just digest, Right (Just options)) -> voteIn digest options st

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
-- default test user: resolves each voted option text to its index in the
-- digest's options (guard failure listing the poll's actual options on an
-- unknown text) and sends the ids.
voteIn :: PollDigest -> [Text] -> ScenarioState app -> TelegramTestScript (ScenarioState app, Maybe a)
voteIn = voteInAs defaultTestUserId

-- | 'voteIn' from a specific user — the engine behind every vote step
-- ('userVotesFor'\/'userVotesIn' pass 'defaultTestUserId', the member pair
-- passes the login's resolved id).
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
