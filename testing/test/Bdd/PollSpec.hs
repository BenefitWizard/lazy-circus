{-# LANGUAGE OverloadedStrings #-}

{- | Poll-smoke vertical acceptance for the BDD stack: a full @.feature@ →
'gherkinSpec' → poll-bot round trip that NEVER contacts PostgreSQL.

The bot under test is a hand-built 'LazyCircus.App.Default.DefaultApp' whose
pool create action is 'fail' ('TestSupport.DbFreeApp.mkDbFreeApp'), so the
smoke passes with PostgreSQL stopped; the scenario touches only the Telegram
sub-language.

The round trip: the inline feature is turned into an hspec tree by
'gherkinSpec'; the STATIC registry reuses the library Telegram step
dictionary — 'LazyCircus.Testing.Bdd.Tg.botSendsPoll' (with the poll options
attached as a @| ... |@ step table) for the @Then@ phase and
'LazyCircus.Testing.Bdd.Tg.userVotesFor' \/
'LazyCircus.Testing.Bdd.Tg.userVotesIn' (single option via the quoted capture,
multi-vote via the options table) for the @When@ phase; the @When@ "the user
sends" step feeds the user's words through the canonical @tgTest@ driver.

The bot's buildAction mirrors the demo's poll flow
('BotHandler.dispatch'): a @\/poll@ command sends a NON-anonymous poll
(anonymous polls never produce @poll_answer@ updates) and registers the
assigned poll id in a spec-local poll registry (the 'SpecPollRegistry' shape
of the demo library's private @PollRegistry@); the chat-less @poll_answer@
update is dispatched BEFORE the chat-id gate — the registry recovers the
chat — and is answered with the voted option ids.

This spec is also the blessing ground for the extended 'ObsTgPoll'
observation shape (id, poll id and options in the shared journal): the full
shape survives three different scenarios below, satisfying the journal's
blessing rule.

Coverage: (1) a poll send observed with question AND options from the step
table; (2) a single vote resolved through the consumed poll's 'PollDigest'
and acknowledged with the voted option index; (3) a table-driven multi-vote
acknowledged with both indexes.
-}
module Bdd.PollSpec (spec) where

import LazyCircus (tgScript)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.App.Service (NoServiceLib)
import LazyCircus.Scenario (ScenarioProgram, evalScript, runArbitraryIO)
import LazyCircus.Scene.Telegram.Lang qualified as Tg (sendMessage, sendPoll)
import LazyCircus.Script (Script)
import LazyCircus.Testing.Bdd.Journal (Observation (..))
import LazyCircus.Testing.Bdd.Pattern (Pattern, lookupParam)
import LazyCircus.Testing.Bdd.Runner
    ( FeatureSource (..)
    , ScenarioRegistry
    , ScenarioVerifier
    , expectScenarioSuccess
    , gherkinSpec
    )
import LazyCircus.Testing.Bdd.Step (givenDef, mkRegistry, whenDef)
import LazyCircus.Testing.Bdd.Tg
    ( botRepliesWithMessage
    , botSendsPoll
    , tgTestBootstrap
    , userVotesFor
    , userVotesIn
    )
import LazyCircus.Testing.Performer
    ( Mocks
    , TestConfig
    , runScenarioProgram
    , runWithConfig
    )
import LazyCircus.Testing.TgTest
    ( TelegramTestScript
    , defaultTgTestConfig
    , sendMessage
    )
import RIO
import RIO.HashMap qualified as HM
import RIO.Text qualified as T
import Telegram.Bot.API
    ( ChatId
    , InputPollOption (..)
    , PollAnswer
    , SomeChatId (..)
    , Update
    , defSendMessage
    , defSendPoll
    , messageText
    , pollAnswerOptionIds
    , pollAnswerPollId
    , sendPollIsAnonymous
    , updateMessage
    )
import Telegram.Bot.API.Types (PollId (..))
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

-- | Prefix of the bot's vote acknowledgement; the voted option indexes
-- follow in @tshow@ form (e.g. @\"🗳 голос учтён: [1]\"@).
ackPrefix :: Text
ackPrefix = "🗳 голос учтён: "

-- | The acknowledgement text for the given voted option texts: their indexes
-- resolved against 'pollOptionTexts' — the same projection the mocked
-- performer journals, so the feature's @Then@ texts stay in sync with the
-- bot's reply by construction.
voteAckText :: [Text] -> Text
voteAckText voted = ackPrefix <> tshow (map optionIndexOf voted)
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

-- | The smoke's feature document: a poll send observed with its option
-- table, a single vote acknowledged by index, and a table-driven multi-vote
-- acknowledged by both indexes.
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
            , "    Then the bot replies with \"" <> voteAckText [pollOptionTexts !! 1] <> "\""
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
            , "    Then the bot replies with \"" <> voteAckText [pollOptionTexts !! 0, pollOptionTexts !! 2] <> "\""
            ]

-- | The @When@ pattern of the user-message step: the quoted span is the
-- user's message.
sendsPattern :: Pattern
sendsPattern = "the user sends \"$msg\""

-- | The STATIC poll registry, shared by every scenario of the feature: the
-- Given is a no-op marker, the user-message When feeds the captured words
-- through the @tgTest@ DSL, and the poll steps come from the library
-- dictionary (they read their expected values from their own captures and
-- tables).
pollStepRegistry :: ScenarioRegistry NoServiceLib () TelegramTestScript
pollStepRegistry = mkRegistry
    [ givenDef "the poll bot is awake" (\_params -> pure . id)
    , whenDef sendsPattern $ \params st -> do
        _ <- sendMessage (fromMaybe "" (lookupParam "$msg" params))
        pure (st, Nothing)
    , botSendsPoll
    , userVotesFor
    , userVotesIn
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
                case mChatId of
                    Nothing -> pure ()
                    Just chatId ->
                        runWithConfig app cfg mocks $
                            runScenarioProgram (voteAckScenario chatId (pollAnswerOptionIds pa))
            Nothing -> case (updateChatId update, updateMessage update >>= messageText) of
                (Just chatId, Just "/poll") ->
                    runWithConfig app cfg mocks $
                        runScenarioProgram (sendPollScenario polls chatId)
                _ -> pure ()

-- | The @\/poll@ scenario: sends a NON-anonymous poll (anonymous polls never
-- produce @poll_answer@ updates — the vote scenarios depend on the
-- @poll_answer@ delivery) and registers its assigned poll id against the
-- chat, so the chat-less vote update can be routed back.
sendPollScenario :: SpecPollRegistry -> ChatId -> ScenarioProgram Script NoServiceLib ()
sendPollScenario polls chatId = do
    (pollId, _) <-
        evalScript $
            tgScript pollBotName $
                Tg.sendPoll
                    (defSendPoll (SomeChatId chatId) pollQuestion pollOptionRequests)
                        { sendPollIsAnonymous = Just False
                        }
    runArbitraryIO $ atomically $ registerSpecPoll polls pollId chatId

-- | The vote-acknowledgement scenario: replies to the poll's chat with the
-- voted option indexes (the text the feature's @Then@ asserts).
voteAckScenario :: ChatId -> [Int] -> ScenarioProgram Script NoServiceLib ()
voteAckScenario chatId optionIds =
    void $
        evalScript $
            tgScript pollBotName $
                Tg.sendMessage (defSendMessage (SomeChatId chatId) (ackPrefix <> tshow optionIds))
