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
observation shape (id, poll id, options plus the thread id, anonymity flag
and close date of the send request in the shared journal): the full shape
survives the scenarios below, satisfying the journal's blessing rule.

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
both hops end-to-end; (6) the observability fields — the @\/poll@ scenario
pins @Just@-values via the publicness step plus digest pins, the
@\/anonpoll@ scenario pins the explicit @Just True@ and the honest
@Nothing@s; (7) the publicness steps' refusal before a poll is consumed
(the poll IS journaled, just not consumed).
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
import LazyCircus.Testing.Bdd.Step (StepDef, StepOutcome (..), givenDef, mkRegistry, thenDef)
import LazyCircus.Testing.Bdd.Tg
    ( botRepliesWithMessage
    , botSendsPoll
    , defaultUserTakesStage
    , memberTakesStage
    , memberVotesFor
    , memberVotesIn
    , pollIsAnonymous
    , pollIsPublic
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
    , tgeDescription
    , tgTestWithMocks
    )
import LazyCircus.Testing.Updates (defaultTestUserId, userIdForLogin)
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
    , messageText
    , pollAnswerOptionIds
    , pollAnswerPollId
    , pollAnswerUser
    , sendPollCloseDate
    , sendPollIsAnonymous
    , sendPollMessageThreadId
    , updateMessage
    , userId
    )
import Telegram.Bot.API.Types (MessageThreadId (..), PollId (..))
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

-- | The smoke's feature document: a poll send observed with its option
-- table, a single vote acknowledged by index and voter, a table-driven
-- multi-vote acknowledged by both indexes and the voter, two cast members
-- voting as themselves (single-option and table member-vote forms)
-- acknowledged with THEIR voter ids, the acting-user switch proven
-- end-to-end (a member takes the stage — @the user ...@ steps act as them;
-- the default user takes it back), and the two observability scenarios (a
-- public poll pinned to the announcement topic; an anonymous poll leaving
-- thread and close date unset).
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
-- sibling pin: 'pdIsAnonymous' is @Just True@ (explicit) while 'pdThreadId'
-- and 'pdCloseDate' are 'Nothing' (the @\/anonpoll@ request leaves them
-- unset), proving the digest's 'Maybe' projection observes the ABSENCE
-- honestly.
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
    , digestCarriesAnnouncementSettings
    , digestLeavesAnnouncementSettingsUnset
    , userVotesFor
    , userVotesIn
    , memberVotesFor
    , memberVotesIn
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
-- registered. A fresh registry is created per scenario run.
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
            Nothing -> case (updateChatId update, updateMessage update >>= messageText) of
                (Just chatId, Just "/poll") ->
                    runWithConfig app cfg mocks $
                        runScenarioProgram (sendPollScenario polls chatId)
                (Just chatId, Just "/anonpoll") ->
                    runWithConfig app cfg mocks $
                        runScenarioProgram (anonPollScenario polls chatId)
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

-- | The vote-acknowledgement scenario: replies to the poll's chat with the
-- voted option indexes and the voter's id (the text the feature's @Then@
-- asserts, through the shared 'voteAckBody' projection).
voteAckScenario :: ChatId -> UserId -> [Int] -> ScenarioProgram Script NoServiceLib ()
voteAckScenario chatId voterId optionIds =
    void $
        evalScript $
            tgScript pollBotName $
                Tg.sendMessage (defSendMessage (SomeChatId chatId) (voteAckBody voterId optionIds))
