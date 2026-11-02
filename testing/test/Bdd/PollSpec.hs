{-# LANGUAGE OverloadedStrings #-}

{- | Poll-smoke vertical acceptance for the BDD stack: a full @.feature@ →
'gherkinSpec' → poll-bot round trip that NEVER contacts PostgreSQL.

The bot under test is a hand-built 'LazyCircus.App.Default.DefaultApp' whose
pool create action is 'fail' ('TestSupport.DbFreeApp.mkDbFreeApp'), so the
smoke passes with PostgreSQL stopped; the scenario touches only the Telegram
sub-language.

The round trip: the inline feature is turned into an hspec tree by
'gherkinSpec'; the STATIC registry is ENTIRELY library dictionary —
'LazyCircus.Testing.Bdd.Tg.botSendsPoll' (with the poll options attached as a
@| ... |@ step table) for the @Then@ phase, and for the @When@ phase
'LazyCircus.Testing.Bdd.Tg.userSends' (feeding the captured words through the
canonical @tgTest@ driver), the vote pair
'LazyCircus.Testing.Bdd.Tg.userVotesFor' \/
'LazyCircus.Testing.Bdd.Tg.userVotesIn' (single option via the quoted capture,
multi-vote via the options table), their multi-actor shorthand siblings
'LazyCircus.Testing.Bdd.Tg.memberVotesFor' \/
'LazyCircus.Testing.Bdd.Tg.memberVotesIn' (voting as the named cast member,
resolved through 'LazyCircus.Testing.Updates.userIdForLogin') and the
acting-user switch 'LazyCircus.Testing.Bdd.Tg.memberTakesStage' \/
'LazyCircus.Testing.Bdd.Tg.defaultUserTakesStage'.

The bot's buildAction mirrors the demo's poll flow
('BotHandler.dispatch'): a @\/poll@ command sends a NON-anonymous poll
(anonymous polls never produce @poll_answer@ updates) and registers the
assigned poll id in a spec-local poll registry (the 'SpecPollRegistry' shape
of the demo library's private @PollRegistry@); the chat-less @poll_answer@
update is dispatched BEFORE the chat-id gate — the registry recovers the
chat — and is answered with the voted option ids AND the voter's user id
(read from the update's @user@). The voter-aware ack is what makes the
member-vote scenarios meaningful: without it the round trip would pass even
if every vote arrived as the default test user.

This spec is also the blessing ground for the extended 'ObsTgPoll'
observation shape (id, poll id, options plus the thread id, anonymity flag,
the choice flags — multiple answers, re-voting, option shuffling — and the
close date of the send request in the shared journal): the full shape
survives the scenarios below, satisfying the journal's blessing rule. The
digest's 'pdMsgId' (the announcement's message id) is proven by the
correction-reply scenarios: a spec-local When step replies to the
announcement through it ('LazyCircus.Testing.TgTest.sendReplyByUser'), the
bot resolves the reply target back to the poll, and a reply to any other
message is ignored — journal silence asserted by a dedicated verifier.

Coverage: (1) a poll send observed with question AND options from the step
table; (2) a single default-user vote resolved through the consumed poll's
'PollDigest' and acknowledged with the voted option index and the voter's
id; (3) a table-driven default-user multi-vote acknowledged with both
indexes and the voter's id; (4) two cast members voting as themselves
(single-option and table forms of the member vote steps) acknowledged with
THEIR user ids — proving per-voter identity survives the round trip; (5)
the acting-user mechanism: 'memberTakesStage' redirects every subsequent
user-named step (the @the user votes ...@ form here) to the member and
'defaultUserTakesStage' hands the stage back — the voter-aware ack proves
both hops end-to-end; (6) a member's correction reply to the announcement —
fed as a reply update against the digest's 'pdMsgId', resolved by the bot
through the poll registry, acknowledged with the resolved poll id — and its
negative twin: a correction reply to an UNRELATED message id is ignored
(zero acknowledgement messages in the journal); (7) the observability
fields — the @\/poll@ scenario pins @Just@-values via the publicness step
plus digest pins, the @\/anonpoll@ scenario pins the explicit @Just True@
and the honest @Nothing@s; (8) the publicness steps' refusal before a poll
is consumed (the poll IS journaled, just not consumed); (9) the choice-flag
observability — the @\/fancypoll@ scenario pins the explicit @Just True@
shuffle\/re-vote\/multiple-answers flags through the choice-step sextet and
digest pins, the @\/plainpoll@ scenario pins their explicit @Just False@
siblings, and the @\/anonpoll@ scenario pins the honest @Nothing@s for all
three flags.
-}
module Bdd.PollSpec (spec) where

import LazyCircus (tgScript)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.App.Service (NoServiceLib)
import LazyCircus.Scenario (ScenarioProgram, evalScript, runArbitraryIO)
import LazyCircus.Scene.Telegram.Lang qualified as Tg (sendMessage, sendPoll)
import LazyCircus.Script (Script)
import LazyCircus.Testing.Bdd.Given (appContextFor)
import LazyCircus.Testing.Bdd.Journal
    ( DialogState (..)
    , Observation (..)
    , PollDigest (..)
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
import LazyCircus.Testing.Bdd.Pattern (lookupParam)
import LazyCircus.Testing.Bdd.Step (StepDef, StepOutcome (..), givenDef, mkRegistry, thenDef, whenDef)
import LazyCircus.Testing.Bdd.Tg
    ( botRepliesWithMessage
    , botSendsPoll
    , defaultUserTakesStage
    , memberTakesStage
    , memberVotesFor
    , memberVotesIn
    , pollAllowsMultipleAnswers
    , pollAllowsRevote
    , pollForbidsRevote
    , pollIsAnonymous
    , pollIsPublic
    , pollIsSingleChoice
    , pollOptionsAreNotShuffled
    , pollOptionsAreShuffled
    , tgTestBootstrap
    , userSends
    , userVotesFor
    , userVotesIn
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
    , sendReplyByUser
    , tgeDescription
    , tgTestWithMocks
    )
import LazyCircus.Testing.Updates (defaultTestChatId, defaultTestUserId, userIdForLogin)
import RIO
import RIO.HashMap qualified as HM
import RIO.Text qualified as T
import Telegram.Bot.API
    ( ChatId
    , InputPollOption (..)
    , PollAnswer
    , SomeChatId (..)
    , Update
    , UserId (..)
    , defSendMessage
    , defSendPoll
    , messageMessageId
    , messageReplyToMessage
    , messageText
    , pollAnswerOptionIds
    , pollAnswerPollId
    , pollAnswerUser
    , sendPollAllowsMultipleAnswers
    , sendPollAllowsRevoting
    , sendPollCloseDate
    , sendPollIsAnonymous
    , sendPollMessageThreadId
    , sendPollShuffleOptions
    , updateMessage
    , userId
    )
import Telegram.Bot.API.Types (Message, MessageId (..), MessageThreadId (..), PollId (..))
import Telegram.Bot.API.GettingUpdates (updateChatId, updatePollAnswer)
import Test.Hspec
import TestSupport.DbFreeApp (mkDbFreeApp)

--------------------------------------------------------------------------------
-- The spec tree
--------------------------------------------------------------------------------

-- | The vertical acceptance: the poll feature runs embedded in this tree (so
-- the runner's meta-test and ambiguity probe are part of it).
spec :: Spec
spec = do
    app <- runIO (mkDbFreeApp pollBotName)
    describe "Poll smoke (feature -> gherkinSpec -> poll bot, no PostgreSQL)" $
        gherkinSpec
            (FeatureInline "poll feature" pollFeature)
            (\_ -> pure pollStepRegistry)
            (tgTestBootstrap defaultTgTestConfig (buildPollAction app))
            pollVerifier
    describe "Poll correction reply ignoring (feature -> gherkinSpec -> poll bot, no PostgreSQL)" $
        gherkinSpec
            (FeatureInline "poll reply ignoring feature" replyIgnoredFeature)
            (\_ -> pure pollStepRegistry)
            (tgTestBootstrap defaultTgTestConfig (buildPollAction app))
            replyIgnoredVerifier
    describe "Poll publicness refusal (feature -> gherkinSpec -> guard failure, no PostgreSQL)" $ do
        refusalReason <- runIO (newIORef (Nothing :: Maybe Text))
        gherkinSpec
            (FeatureInline "poll publicness refusal feature" refusalFeature)
            (\_ -> pure pollStepRegistry)
            (refusalBootstrap defaultTgTestConfig (buildPollAction app) refusalReason)
            (refusalVerifier refusalReason)

--------------------------------------------------------------------------------
-- The poll feature and its registry
--------------------------------------------------------------------------------

-- | The bot name the scenarios address (@tgScript@ resolves it).
pollBotName :: Text
pollBotName = "poll-bot"

-- | The poll question the @\/poll@ command sends. Named so the feature text
-- and the bot's request stay in sync by construction.
pollQuestion :: Text
pollQuestion = "Кого позвать в шапито?"

-- | The poll option texts, in the order they are sent (option index N of the
-- @poll_answer@ update is the N-th text here).
pollOptionTexts :: [Text]
pollOptionTexts = ["Жонглёры", "Акробаты", "Дрессированные собачки"]

-- | The request form of 'pollOptionTexts': plain-text options (no parse mode,
-- no entities), built positionally as the API requires.
pollOptionRequests :: [InputPollOption]
pollOptionRequests = map (\txt -> InputPollOption txt Nothing Nothing) pollOptionTexts

-- | The close date the @\/poll@ request pins ('sendPollCloseDate', raw Unix
-- seconds; 2026-11-30T12:00:00Z — the library stores it raw, interpretation
-- stays with the consumer). Named so the request and the digest pins stay in
-- sync by construction.
pollCloseDate :: Int
pollCloseDate = 1796040000

-- | The target forum topic of the @\/poll@ request
-- ('sendPollMessageThreadId') — the announcement topic stand-in. Named so the
-- request and the digest pins stay in sync by construction.
pollThreadId :: MessageThreadId
pollThreadId = MessageThreadId 42

-- | Prefix of the bot's vote acknowledgement; the voted option indexes and
-- the voter's numeric id follow in @tshow@ form
-- (e.g. @\"🗳 голос учтён: [1] от 2000000123\"@).
ackPrefix :: Text
ackPrefix = "🗳 голос учтён: "

-- | Renders the vote acknowledgement for the given voter id and voted option
-- indexes — the single projection the bot's reply and the feature's expected
-- texts both go through, so they stay in sync by construction.
voteAckBody :: UserId -> [Int] -> Text
voteAckBody voterId optionIds =
    ackPrefix <> tshow optionIds <> " от " <> tshow voterNumber
  where
    -- | The voter's numeric id (the 'UserId' newtype's 'Show' would render
    -- the constructor).
    UserId voterNumber = voterId

-- | The expected acknowledgement text for the given voter and voted option
-- texts: their indexes resolved against 'pollOptionTexts' fed through
-- 'voteAckBody'.
voteAckText :: UserId -> [Text] -> Text
voteAckText voterId voted = voteAckBody voterId (map optionIndexOf voted)
  where
    -- | 0-based index of an option text in 'pollOptionTexts' (a total lookup:
    -- the feature only votes for options it declares).
    optionIndexOf opt =
        fromMaybe
            (error "PollSpec: voted option is not in pollOptionTexts")
            (lookup opt (zip pollOptionTexts [0 ..]))

-- | Renders one options-table row for the feature document.
optionRow :: Text -> Text
optionRow opt = "        | " <> opt <> " |"

-- | The @alice@ cast member of the members-vote scenario.
memberAlice :: Text
memberAlice = "@alice"

-- | The @bob@ cast member of the members-vote scenario.
memberBob :: Text
memberBob = "@bob"

-- | The @carol@ cast member of the acting-user scenario.
memberCarol :: Text
memberCarol = "@carol"

-- | The @sensei@ cast member of the correction-reply scenarios (the club
-- instructor adjusting attendance by replying to the announcement).
memberSensei :: Text
memberSensei = "@sensei"

-- | The correction the reply scenarios carry (a @+login@ attendance
-- adjustment).
correctionText :: Text
correctionText = "+@olga"

-- | The message id the mock assigns to a scenario's single poll
-- announcement: fresh mocks per scenario and the poll is the bot's FIRST side
-- effect, so the assignment is deterministic.
announcementMsgId :: MessageId
announcementMsgId = MessageId 0

-- | The mock-assigned poll id of an announcement message — bijective with the
-- message id through the mock's @poll-<message id>@ derivation (the same rule
-- 'pdPollId' of a digest with 'pdMsgId' @n@ follows). The feature's expected
-- acknowledgement goes through it, so the pin and the mock's id assignment
-- stay in sync by construction.
mockPollIdOf :: MessageId -> PollId
mockPollIdOf (MessageId n) = PollId ("poll-" <> tshow n)

-- | A message id no scenario announcement ever carries: the mock's message-id
-- counter starts at 0 per scenario (fresh mocks) and a scenario journals a
-- handful of bot messages at most.
unrelatedMsgId :: MessageId
unrelatedMsgId = MessageId 999

-- | Renders the correction acknowledgement for a correction text and the poll
-- id the reply target resolved to — the single projection the bot's reply and
-- the feature's expected texts both go through, so they stay in sync by
-- construction.
correctionAckText :: Text -> PollId -> Text
correctionAckText correction (PollId pollIdText) =
    "✅ корректировка учтена: " <> correction <> " на " <> pollIdText

-- | The smoke's feature document: a poll send observed with its option
-- table, a single vote acknowledged by index and voter, a table-driven
-- multi-vote acknowledged by both indexes and the voter, two cast members
-- voting as themselves (single-option and table member-vote forms)
-- acknowledged with THEIR voter ids, the acting-user switch proven
-- end-to-end (a member takes the stage — @the user ...@ steps act as them;
-- the default user takes it back), a correction reply to the announcement
-- acknowledged with the poll id the reply target resolved to (the reply
-- rides 'pdMsgId' of the consumed digest), the two observability scenarios
-- (a public poll pinned to the announcement topic; an anonymous poll leaving
-- thread and close date unset), and the two choice-flag scenarios (a
-- @\/fancypoll@ with every choice flag explicitly @True@; a @\/plainpoll@
-- with every choice flag explicitly @False@).
pollFeature :: Text
pollFeature =
    T.unlines $
        [ "Feature: Poll bot dialog"
        , ""
        , "  Scenario: sends a poll with its options"
        , "    Given the poll bot is awake"
        , "    When the user sends \"/poll\""
        , "    Then the bot sends a poll \"" <> pollQuestion <> "\""
        ]
            ++ map optionRow pollOptionTexts
            ++ [ ""
               , "  Scenario: votes for one option"
               , "    Given the poll bot is awake"
               , "    When the user sends \"/poll\""
               , "    Then the bot sends a poll \"" <> pollQuestion <> "\""
               ]
            ++ map optionRow pollOptionTexts
            ++
            [ "    When the user votes for \"" <> (pollOptionTexts !! 1) <> "\" in the poll"
            , "    Then the bot replies with \"" <> voteAckText defaultTestUserId [pollOptionTexts !! 1] <> "\""
            , ""
            , "  Scenario: votes for two options at once"
            , "    Given the poll bot is awake"
            , "    When the user sends \"/poll\""
            , "    Then the bot sends a poll \"" <> pollQuestion <> "\""
            ]
            ++ map optionRow pollOptionTexts
            ++
            [ "    When the user votes in the poll"
            , optionRow (pollOptionTexts !! 0)
            , optionRow (pollOptionTexts !! 2)
            , "    Then the bot replies with \"" <> voteAckText defaultTestUserId [pollOptionTexts !! 0, pollOptionTexts !! 2] <> "\""
            , ""
            , "  Scenario: members vote as themselves"
            , "    Given the poll bot is awake"
            , "    When the user sends \"/poll\""
            , "    Then the bot sends a poll \"" <> pollQuestion <> "\""
            ]
            ++ map optionRow pollOptionTexts
            ++
            [ "    When the member \"" <> memberAlice <> "\" votes for \"" <> (pollOptionTexts !! 1) <> "\" in the poll"
            , "    Then the bot replies with \"" <> voteAckText (userIdForLogin memberAlice) [pollOptionTexts !! 1] <> "\""
            , "    When the member \"" <> memberBob <> "\" votes in the poll"
            , optionRow (pollOptionTexts !! 0)
            , optionRow (pollOptionTexts !! 2)
            , "    Then the bot replies with \"" <> voteAckText (userIdForLogin memberBob) [pollOptionTexts !! 0, pollOptionTexts !! 2] <> "\""
            , ""
            , "  Scenario: the acting member takes the stage"
            , "    Given the poll bot is awake"
            , "    When the user sends \"/poll\""
            , "    Then the bot sends a poll \"" <> pollQuestion <> "\""
            ]
            ++ map optionRow pollOptionTexts
            ++
            [ "    When the member \"" <> memberCarol <> "\" takes the stage"
            , "    And the user votes for \"" <> (pollOptionTexts !! 0) <> "\" in the poll"
            , "    Then the bot replies with \"" <> voteAckText (userIdForLogin memberCarol) [pollOptionTexts !! 0] <> "\""
            , "    When the default user takes the stage"
            , "    And the user votes for \"" <> (pollOptionTexts !! 1) <> "\" in the poll"
            , "    Then the bot replies with \"" <> voteAckText defaultTestUserId [pollOptionTexts !! 1] <> "\""
            ]
            ++ [ ""
               , "  Scenario: a member's correction reply to the announcement is acknowledged"
               , "    Given the poll bot is awake"
               , "    When the user sends \"/poll\""
               , "    Then the bot sends a poll \"" <> pollQuestion <> "\""
               ]
            ++ map optionRow pollOptionTexts
            ++
            [ "    When the member \"" <> memberSensei <> "\" replies \"" <> correctionText <> "\" to the poll announcement"
            , "    Then the bot replies with \"" <> correctionAckText correctionText (mockPollIdOf announcementMsgId) <> "\""
            ]
            ++ [ ""
               , "  Scenario: sends a public poll pinned to the announcement topic"
               , "    Given the poll bot is awake"
               , "    When the user sends \"/poll\""
               , "    Then the bot sends a poll \"" <> pollQuestion <> "\""
               ]
            ++ map optionRow pollOptionTexts
            ++
            [ "    And the poll is public"
            , "    And the poll digest carries the announcement settings"
            , ""
            , "  Scenario: sends an anonymous poll leaving thread and close date unset"
            , "    Given the poll bot is awake"
            , "    When the user sends \"/anonpoll\""
               , "    Then the bot sends a poll \"" <> pollQuestion <> "\""
            ]
            ++ map optionRow pollOptionTexts
            ++
            [ "    And the poll is anonymous"
            , "    And the poll digest leaves thread and close date unset"
            , ""
            , "  Scenario: sends a poll with shuffled, revotable, multiple-choice options"
            , "    Given the poll bot is awake"
            , "    When the user sends \"/fancypoll\""
            , "    Then the bot sends a poll \"" <> pollQuestion <> "\""
            ]
            ++ map optionRow pollOptionTexts
            ++
            [ "    And the poll options are shuffled"
            , "    And the poll allows re-voting"
            , "    And the poll allows multiple answers"
            , "    And the poll digest carries the choice settings"
            , ""
            , "  Scenario: sends a plain poll without shuffling, re-voting or multiple choice"
            , "    Given the poll bot is awake"
            , "    When the user sends \"/plainpoll\""
            , "    Then the bot sends a poll \"" <> pollQuestion <> "\""
            ]
            ++ map optionRow pollOptionTexts
            ++
            [ "    And the poll options are not shuffled"
            , "    And the poll does not allow re-voting"
            , "    And the poll is single choice"
            , "    And the poll digest pins the plain choice settings"
            ]

-- | @the poll digest carries the announcement settings@ — And-continuation
-- pinning the three observability fields of the last consumed poll's digest
-- against the spec's named fixtures ('pollThreadId', 'pollCloseDate' and the
-- explicit public flag) — the same constants the @\/poll@ request is built
-- from, so the pin and the send stay in sync by construction.
--
-- PRE-CONTRACT: A poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise.
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not. Each field has its own guard reason rendering expected vs actual.
digestCarriesAnnouncementSettings :: StepDef TelegramTestScript c (ScenarioState app) a
digestCarriesAnnouncementSettings =
    thenDef "the poll digest carries the announcement settings" $ \_params st ->
        case dsLastPoll (ssDialog st) of
            Nothing ->
                guardWith noConsumedPollReason False
                    >> pure (st, Nothing)
            Just digest -> do
                guardWith
                    ("expected the poll's thread id to be " <> tshow (Just pollThreadId) <> ", got: " <> tshow (pdThreadId digest))
                    (pdThreadId digest == Just pollThreadId)
                guardWith
                    ("expected the poll's anonymity flag to be Just False, got: " <> tshow (pdIsAnonymous digest))
                    (pdIsAnonymous digest == Just False)
                guardWith
                    ("expected the poll's close date to be " <> tshow (Just pollCloseDate) <> ", got: " <> tshow (pdCloseDate digest))
                    (pdCloseDate digest == Just pollCloseDate)
                pure (st, Nothing)

-- | @the poll digest leaves thread and close date unset@ — the anonymous
-- sibling pin: 'pdIsAnonymous' is @Just True@ (explicit) while 'pdThreadId',
-- 'pdCloseDate' AND the three choice flags are 'Nothing' (the @\/anonpoll@
-- request leaves them all unset), proving the digest's 'Maybe' projection
-- observes the ABSENCE honestly.
--
-- PRE-CONTRACT: A poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise.
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not. Each field has its own guard reason rendering expected vs actual.
digestLeavesAnnouncementSettingsUnset :: StepDef TelegramTestScript c (ScenarioState app) a
digestLeavesAnnouncementSettingsUnset =
    thenDef "the poll digest leaves thread and close date unset" $ \_params st ->
        case dsLastPoll (ssDialog st) of
            Nothing ->
                guardWith noConsumedPollReason False
                    >> pure (st, Nothing)
            Just digest -> do
                guardWith
                    ("expected the poll's thread id to be Nothing, got: " <> tshow (pdThreadId digest))
                    (pdThreadId digest == Nothing)
                guardWith
                    ("expected the poll's anonymity flag to be Just True, got: " <> tshow (pdIsAnonymous digest))
                    (pdIsAnonymous digest == Just True)
                guardWith
                    ("expected the poll's close date to be Nothing, got: " <> tshow (pdCloseDate digest))
                    (pdCloseDate digest == Nothing)
                guardWith
                    ("expected the poll's multiple-answers flag to be Nothing, got: " <> tshow (pdAllowsMultipleAnswers digest))
                    (pdAllowsMultipleAnswers digest == Nothing)
                guardWith
                    ("expected the poll's re-voting flag to be Nothing, got: " <> tshow (pdAllowsRevoting digest))
                    (pdAllowsRevoting digest == Nothing)
                guardWith
                    ("expected the poll's option-shuffle flag to be Nothing, got: " <> tshow (pdShuffleOptions digest))
                    (pdShuffleOptions digest == Nothing)
                pure (st, Nothing)

-- | @the poll digest carries the choice settings@ — And-continuation pinning
-- the three choice flags of the last consumed poll's digest to the explicit
-- @Just True@ values the @\/fancypoll@ request sets — the same flags the
-- request is built from, so the pin and the send stay in sync by construction.
--
-- PRE-CONTRACT: A poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise.
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not. Each field has its own guard reason rendering expected vs actual.
digestCarriesChoiceSettings :: StepDef TelegramTestScript c (ScenarioState app) a
digestCarriesChoiceSettings =
    thenDef "the poll digest carries the choice settings" $ \_params st ->
        case dsLastPoll (ssDialog st) of
            Nothing ->
                guardWith noConsumedPollReason False
                    >> pure (st, Nothing)
            Just digest -> do
                guardWith
                    ("expected the poll's multiple-answers flag to be Just True, got: " <> tshow (pdAllowsMultipleAnswers digest))
                    (pdAllowsMultipleAnswers digest == Just True)
                guardWith
                    ("expected the poll's re-voting flag to be Just True, got: " <> tshow (pdAllowsRevoting digest))
                    (pdAllowsRevoting digest == Just True)
                guardWith
                    ("expected the poll's option-shuffle flag to be Just True, got: " <> tshow (pdShuffleOptions digest))
                    (pdShuffleOptions digest == Just True)
                pure (st, Nothing)

-- | @the poll digest pins the plain choice settings@ — the explicit
-- @Just False@ sibling pin: every choice flag of the last consumed poll's
-- digest carries the value the @\/plainpoll@ request set (no shuffling, no
-- re-voting, single choice).
--
-- PRE-CONTRACT: A poll has been consumed by a previous step (e.g.
-- 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts with an
-- explanatory reason otherwise.
-- POST-CONTRACT: NEVER waits and NEVER consumes: the journal, the consumed
-- set and the dialog state pass through untouched whether the assertion holds
-- or not. Each field has its own guard reason rendering expected vs actual.
digestPinsPlainChoiceSettings :: StepDef TelegramTestScript c (ScenarioState app) a
digestPinsPlainChoiceSettings =
    thenDef "the poll digest pins the plain choice settings" $ \_params st ->
        case dsLastPoll (ssDialog st) of
            Nothing ->
                guardWith noConsumedPollReason False
                    >> pure (st, Nothing)
            Just digest -> do
                guardWith
                    ("expected the poll's multiple-answers flag to be Just False, got: " <> tshow (pdAllowsMultipleAnswers digest))
                    (pdAllowsMultipleAnswers digest == Just False)
                guardWith
                    ("expected the poll's re-voting flag to be Just False, got: " <> tshow (pdAllowsRevoting digest))
                    (pdAllowsRevoting digest == Just False)
                guardWith
                    ("expected the poll's option-shuffle flag to be Just False, got: " <> tshow (pdShuffleOptions digest))
                    (pdShuffleOptions digest == Just False)
                pure (st, Nothing)

-- | @the member "$login" replies "$msg" to the poll announcement@ — an
-- in-spec When step (deliberately NOT library vocabulary: a consumer's
-- adjustment steps are domain-phrased). The member replies to the LAST
-- CONSUMED poll's announcement through the digest's 'pdMsgId' — the exact
-- resolution a production correction handler performs on
-- @reply_to_message@: the reply target IS the announcement's message.
--
-- PRE-CONTRACT: Both captures appear inside double quotes in the step text
-- (the pattern's @"$login"@ / @"$msg"@ spans — the runner matched the step,
-- so the captures are present). A poll has been consumed by a previous step
-- (e.g. 'botSendsPoll'), so 'dsLastPoll' holds its digest — the step aborts
-- with an explanatory reason otherwise.
-- POST-CONTRACT: On success one text update whose @reply_to_message@
-- references 'pdMsgId' of the consumed digest has been fed to the bot as the
-- member ('LazyCircus.Testing.Updates.userIdForLogin'); the scenario state
-- passes through unchanged.
memberRepliesToAnnouncement :: StepDef TelegramTestScript c (ScenarioState app) a
memberRepliesToAnnouncement =
    whenDef "the member \"$login\" replies \"$msg\" to the poll announcement" $ \params st ->
        case dsLastPoll (ssDialog st) of
            Nothing ->
                guardWith noConsumedPollReason False
                    >> pure (st, Nothing)
            Just digest -> do
                let login = fromMaybe "" (lookupParam "$login" params)
                    msg = fromMaybe "" (lookupParam "$msg" params)
                _ <- sendReplyByUser (userIdForLogin login) defaultTestChatId (pdMsgId digest) msg
                pure (st, Nothing)

-- | @the member "$login" replies "$msg" to an unrelated message@ — the
-- negative twin of 'memberRepliesToAnnouncement': the reply targets
-- 'unrelatedMsgId', a message id no announcement ever carries, so a correct
-- driver resolves nothing and stays silent. The ignoring itself is asserted
-- by the reply-ignored feature's VERIFIER (journal silence), not by a Then
-- step — a \"bot stays silent\" wait would have to be timeout-based.
--
-- PRE-CONTRACT: Both captures appear inside double quotes in the step text
-- (the runner matched the step, so the captures are present).
-- POST-CONTRACT: One text update whose @reply_to_message@ references
-- 'unrelatedMsgId' has been fed to the bot as the member; the scenario state
-- passes through unchanged.
memberRepliesToUnrelatedMessage :: StepDef TelegramTestScript c (ScenarioState app) a
memberRepliesToUnrelatedMessage =
    whenDef "the member \"$login\" replies \"$msg\" to an unrelated message" $ \params st -> do
        let login = fromMaybe "" (lookupParam "$login" params)
            msg = fromMaybe "" (lookupParam "$msg" params)
        _ <- sendReplyByUser (userIdForLogin login) defaultTestChatId unrelatedMsgId msg
        pure (st, Nothing)

-- | Guard-failure message when the digest-pin steps run before any poll was
-- consumed.
noConsumedPollReason :: Text
noConsumedPollReason =
    "no poll has been consumed yet; a poll-consuming step (e.g. 'the bot sends a poll ...') must run first"

-- | The STATIC poll registry, shared by every scenario of the feature: the
-- Given is a no-op marker and EVERY When step comes from the library
-- dictionary (they read their expected values from their own captures and
-- tables).
pollStepRegistry :: ScenarioRegistry NoServiceLib () TelegramTestScript
pollStepRegistry = mkRegistry
    [ givenDef "the poll bot is awake" (\_params -> pure . id)
    , userSends
    , memberTakesStage
    , defaultUserTakesStage
    , botSendsPoll
    , pollIsPublic
    , pollIsAnonymous
    , pollAllowsMultipleAnswers
    , pollIsSingleChoice
    , pollAllowsRevote
    , pollForbidsRevote
    , pollOptionsAreShuffled
    , pollOptionsAreNotShuffled
    , digestCarriesAnnouncementSettings
    , digestLeavesAnnouncementSettingsUnset
    , digestCarriesChoiceSettings
    , digestPinsPlainChoiceSettings
    , userVotesFor
    , userVotesIn
    , memberVotesFor
    , memberVotesIn
    , memberRepliesToAnnouncement
    , memberRepliesToUnrelatedMessage
    , botRepliesWithMessage
    ]

-- | Verifier: the scenario ran to success, the journal holds exactly one
-- poll observation per scenario (each scenario sends exactly one poll), and
-- everything else journaled is a bot reply message — the exact texts are
-- already asserted by the poll- and reply-consuming steps.
pollVerifier :: ScenarioVerifier ()
pollVerifier scenario outcome observations = do
    expectScenarioSuccess scenario outcome observations
    let isPoll ObsTgPoll{} = True
        isPoll _ = False
        isKnownKind ObsTgPoll{} = True
        isKnownKind ObsTgMessage{} = True
        isKnownKind _ = False
    unless (length (filter isPoll observations) == 1 && all isKnownKind observations) $
        expectationFailure $
            "expected exactly one journaled poll (plus reply messages only), got: " <> show observations

--------------------------------------------------------------------------------
-- The reply-ignoral feature (a correction reply to a non-announcement)
--------------------------------------------------------------------------------

-- | The reply-ignoral feature: the member replies to a message id no
-- announcement ever carries, so a correct driver resolves the target through
-- the poll registry, finds nothing and STAYS SILENT. The silence IS the
-- assertion: the verifier requires the journal to hold exactly the one poll
-- and not a single message — no Then step could express \"the bot said
-- nothing\" without a timeout-based negative wait.
replyIgnoredFeature :: Text
replyIgnoredFeature =
    T.unlines $
        [ "Feature: Poll correction reply ignoring"
        , ""
        , "  Scenario: a correction reply to another message is ignored"
        , "    Given the poll bot is awake"
        , "    When the user sends \"/poll\""
        , "    Then the bot sends a poll \"" <> pollQuestion <> "\""
        ]
            ++ map optionRow pollOptionTexts
            ++
            [ "    When the member \"" <> memberSensei <> "\" replies \"" <> correctionText <> "\" to an unrelated message"
            ]

-- | Verifier: the scenario ran to success and the journal holds EXACTLY the
-- one poll — not a single 'ObsTgMessage': the unrelated correction reply was
-- ignored (a wrong driver would have acknowledged it into the journal).
replyIgnoredVerifier :: ScenarioVerifier ()
replyIgnoredVerifier scenario outcome observations = do
    expectScenarioSuccess scenario outcome observations
    let isPoll ObsTgPoll{} = True
        isPoll _ = False
        isMessage ObsTgMessage{} = True
        isMessage _ = False
    unless (length (filter isPoll observations) == 1) $
        expectationFailure $
            "expected exactly one journaled poll, got: " <> show observations
    case filter isMessage observations of
        [] -> pure ()
        messages ->
            expectationFailure $
                "expected the correction reply to an unrelated message to be ignored, got: " <> show messages

--------------------------------------------------------------------------------
-- The publicness refusal feature (green example for a refusing scenario)
--------------------------------------------------------------------------------

-- | The refusal feature: the publicness step runs while a poll IS journaled
-- (the @\/poll@ send happened) but nothing CONSUMED it yet — 'dsLastPoll' is
-- still 'Nothing', so the step must abort with the no-consumed-poll reason.
refusalFeature :: Text
refusalFeature =
    T.unlines
        [ "Feature: Poll publicness refusal"
        , ""
        , "  Scenario: the publicness step refuses before a poll is consumed"
        , "    Given the poll bot is awake"
        , "    When the user sends \"/poll\""
        , "    Then the poll is public"
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

-- | Verifier: the scenario must have REFUSED with the no-consumed-poll
-- reason (recorded by 'refusalBootstrap'), while the journal still holds
-- exactly one poll — the refusal is about consumption, not about a missing
-- send.
refusalVerifier :: IORef (Maybe Text) -> ScenarioVerifier ()
refusalVerifier errRef _scenario _outcome observations = do
    recorded <- readIORef errRef
    case recorded of
        Nothing ->
            expectationFailure "expected the publicness step to refuse before a poll is consumed, but the scenario succeeded"
        Just reason ->
            unless (T.isInfixOf "no poll has been consumed yet" reason) $
                expectationFailure $
                    "expected the no-consumed-poll refusal, got: " <> T.unpack reason
    let isPoll ObsTgPoll{} = True
        isPoll _ = False
    unless (length (filter isPoll observations) == 1) $
        expectationFailure $
            "expected exactly one journaled poll despite the refusal (the send happened, only the consumption did not), got: " <> show observations

--------------------------------------------------------------------------------
-- The spec-local poll registry
--------------------------------------------------------------------------------

-- | Spec-local, thread-safe registry correlating sent polls to chats — the
-- same shape as the demo library's @PollRegistry@ (a @TVar@ @HashMap@ keyed
-- by the inner 'Text' of 'PollId', because 'PollId' itself has no 'Hashable'):
-- a @poll_answer@ update carries a poll id but NO chat id, so the vote-ack
-- driver needs to remember which chat each poll was sent to. It lives here
-- (not in the shared demo library) because the @common-circus@ internal
-- library is private to the root package.
data SpecPollRegistry = SpecPollRegistry
    { specPollRegistryMap :: !(TVar (HM.HashMap Text ChatId))
      -- ^ poll-id text → chat the poll was sent to
    }

-- | Create an empty spec-local poll registry.
newSpecPollRegistry :: IO SpecPollRegistry
newSpecPollRegistry = SpecPollRegistry <$> newTVarIO HM.empty

-- | Record which chat a poll was sent to.
registerSpecPoll :: SpecPollRegistry -> PollId -> ChatId -> STM ()
registerSpecPoll registry (PollId pollIdText) chatId =
    modifyTVar' (specPollRegistryMap registry) (HM.insert pollIdText chatId)

-- | Look up the chat a poll was sent to ('Nothing' for an unknown poll).
lookupSpecPollChat :: SpecPollRegistry -> PollId -> IO (Maybe ChatId)
lookupSpecPollChat registry (PollId pollIdText) =
    HM.lookup pollIdText <$> readTVarIO (specPollRegistryMap registry)

--------------------------------------------------------------------------------
-- Bootstrap: the DB-free poll app under the canonical tgTest driver
--------------------------------------------------------------------------------

-- | The poll bot's buildAction (the 'Bdd.EchoSmokeSpec.buildEchoAction'
-- shape): the production-style update driver with the test performer
-- substituted. The chat-less @poll_answer@ update is dispatched BEFORE the
-- chat-id gate — exactly like the demo bot's @runUpdate@ — and the chat the
-- poll belongs to is recovered from the 'SpecPollRegistry' the poll send
-- registered. A text message carrying a @reply_to_message@ is dispatched as
-- a correction reply ('correctionReplyDriver'); only plain text falls through
-- to the command branches. A fresh registry is created per scenario run.
-- PRE-CONTRACT: @mocks@ must be the 'Mocks' set the executor wired the
-- runtime with (the runner-owned ones), so the bot's outgoing poll and
-- replies land in the observed mailbox\/journal.
buildPollAction
    :: DefaultApp NoServiceLib
    -> TestConfig ()
    -> Mocks NoServiceLib
    -> IO (Update -> IO ())
buildPollAction app cfg mocks = do
    polls <- newSpecPollRegistry
    pure $ \update ->
        case updatePollAnswer update of
            Just pa -> do
                mChatId <- lookupSpecPollChat polls (pollAnswerPollId pa)
                -- The vote ack is VOTER-AWARE: the voter's id rides in the
                -- update's @user@ (the fake @poll_answer@ builder always sets
                -- it), so the member-vote scenarios can prove per-voter
                -- identity survives the round trip. A vote without a user is
                -- ignored (unreachable with the fake builder).
                case (mChatId, pollAnswerUser pa) of
                    (Just chatId, Just voter) ->
                        runWithConfig app cfg mocks $
                            runScenarioProgram (voteAckScenario chatId (userId voter) (pollAnswerOptionIds pa))
                    _ -> pure ()
            Nothing -> case (updateChatId update, updateMessage update) of
                (Just chatId, Just msg) -> case messageReplyToMessage msg of
                    Just target ->
                        correctionReplyDriver polls app cfg mocks (messageText msg) target
                    Nothing -> case messageText msg of
                        Just "/poll" ->
                            runWithConfig app cfg mocks $
                                runScenarioProgram (sendPollScenario polls chatId)
                        Just "/anonpoll" ->
                            runWithConfig app cfg mocks $
                                runScenarioProgram (anonPollScenario polls chatId)
                        Just "/fancypoll" ->
                            runWithConfig app cfg mocks $
                                runScenarioProgram (fancyPollScenario polls chatId)
                        Just "/plainpoll" ->
                            runWithConfig app cfg mocks $
                                runScenarioProgram (plainPollScenario polls chatId)
                        _ -> pure ()
                _ -> pure ()

-- | The @\/poll@ scenario: sends a NON-anonymous poll (anonymous polls never
-- produce @poll_answer@ updates — the vote scenarios depend on the
-- @poll_answer@ delivery), pinned to the announcement topic
-- ('pollThreadId') with the close date 'pollCloseDate', and registers its
-- assigned poll id against the chat, so the chat-less vote update can be
-- routed back.
sendPollScenario :: SpecPollRegistry -> ChatId -> ScenarioProgram Script NoServiceLib ()
sendPollScenario polls chatId = do
    (pollId, _) <-
        evalScript $
            tgScript pollBotName $
                Tg.sendPoll
                    (defSendPoll (SomeChatId chatId) pollQuestion pollOptionRequests)
                        { sendPollIsAnonymous = Just False
                        , sendPollCloseDate = Just pollCloseDate
                        , sendPollMessageThreadId = Just pollThreadId
                        }
    runArbitraryIO $ atomically $ registerSpecPoll polls pollId chatId

-- | The @\/anonpoll@ scenario: the anonymous sibling of 'sendPollScenario' —
-- the same question and options, but an EXPLICITLY anonymous poll with the
-- thread id and close date left unset, so the digest's 'Maybe' projection
-- honestly observes 'Nothing' for them (the unset fields are themselves
-- observable).
anonPollScenario :: SpecPollRegistry -> ChatId -> ScenarioProgram Script NoServiceLib ()
anonPollScenario polls chatId = do
    (pollId, _) <-
        evalScript $
            tgScript pollBotName $
                Tg.sendPoll
                    (defSendPoll (SomeChatId chatId) pollQuestion pollOptionRequests)
                        { sendPollIsAnonymous = Just True
                        }
    runArbitraryIO $ atomically $ registerSpecPoll polls pollId chatId

-- | The @\/fancypoll@ scenario: the same question and options as
-- 'sendPollScenario', but with every poll CHOICE flag set EXPLICITLY to
-- 'True' — shuffled options, allowed re-voting and multiple answers (the
-- flags the choice-observability scenario pins through both the step sextet
-- and the digest pins).
fancyPollScenario :: SpecPollRegistry -> ChatId -> ScenarioProgram Script NoServiceLib ()
fancyPollScenario polls chatId = do
    (pollId, _) <-
        evalScript $
            tgScript pollBotName $
                Tg.sendPoll
                    (defSendPoll (SomeChatId chatId) pollQuestion pollOptionRequests)
                        { sendPollIsAnonymous = Just False
                        , sendPollAllowsMultipleAnswers = Just True
                        , sendPollAllowsRevoting = Just True
                        , sendPollShuffleOptions = Just True
                        }
    runArbitraryIO $ atomically $ registerSpecPoll polls pollId chatId

-- | The @\/plainpoll@ scenario: the explicit counterpart of
-- 'fancyPollScenario' — every choice flag set EXPLICITLY to 'False' (no
-- option shuffling, no re-voting, single choice), so the strict negative
-- steps and the @Just False@ digest pins have a request to observe.
plainPollScenario :: SpecPollRegistry -> ChatId -> ScenarioProgram Script NoServiceLib ()
plainPollScenario polls chatId = do
    (pollId, _) <-
        evalScript $
            tgScript pollBotName $
                Tg.sendPoll
                    (defSendPoll (SomeChatId chatId) pollQuestion pollOptionRequests)
                        { sendPollIsAnonymous = Just False
                        , sendPollAllowsMultipleAnswers = Just False
                        , sendPollAllowsRevoting = Just False
                        , sendPollShuffleOptions = Just False
                        }
    runArbitraryIO $ atomically $ registerSpecPoll polls pollId chatId

-- | The vote-acknowledgement scenario: replies to the poll's chat with the
-- voted option indexes and the voter's id (the text the feature's @Then@
-- asserts, through the shared 'voteAckBody' projection).
voteAckScenario :: ChatId -> UserId -> [Int] -> ScenarioProgram Script NoServiceLib ()
voteAckScenario chatId voterId optionIds =
    void $
        evalScript $
            tgScript pollBotName $
                Tg.sendMessage (defSendMessage (SomeChatId chatId) (voteAckBody voterId optionIds))

-- | Drive a correction reply: resolve the target message id to the poll the
-- mock assigned it ('mockPollIdOf' — the announcement's message id and its
-- poll id are bijective) and acknowledge the correction in the chat the poll
-- was sent to. An unresolvable target (a reply to anything but an
-- announcement) is IGNORED — no reply, no journal entry — the exact
-- \"reply on the announcement finds the session by the poll's message\"
-- resolution a production adjustment handler rides on.
correctionReplyDriver
    :: SpecPollRegistry
    -> DefaultApp NoServiceLib
    -> TestConfig ()
    -> Mocks NoServiceLib
    -> Maybe Text
    -> Message
    -> IO ()
correctionReplyDriver polls app cfg mocks correction target = do
    let resolvedId = mockPollIdOf (messageMessageId target)
    mChatId <- lookupSpecPollChat polls resolvedId
    case (mChatId, correction) of
        (Just chatId, Just txt) ->
            runWithConfig app cfg mocks $
                runScenarioProgram (correctionAckScenario chatId txt resolvedId)
        _ -> pure ()

-- | The correction-acknowledgement scenario: replies to the poll's chat with
-- the correction text and the poll id the reply target resolved to (the text
-- the feature's @Then@ asserts, through the shared 'correctionAckText'
-- projection).
correctionAckScenario :: ChatId -> Text -> PollId -> ScenarioProgram Script NoServiceLib ()
correctionAckScenario chatId correction resolvedId =
    void $
        evalScript $
            tgScript pollBotName $
                Tg.sendMessage (defSendMessage (SomeChatId chatId) (correctionAckText correction resolvedId))
