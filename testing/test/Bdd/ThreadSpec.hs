{-# LANGUAGE OverloadedStrings #-}

{- | Forum-thread vertical acceptance for the BDD stack: a full @.feature@ →
'gherkinSpec' → thread-echo-bot round trip that NEVER contacts PostgreSQL.

The bot mirrors the incoming @message_thread_id@ back into its reply
(@sendMessageMessageThreadId@) and prefixes @\[topic\]@ when the incoming
message reports @is_topic_message = True@ — so the scenario can assert BOTH
directions of the thread flow with the library steps: the @When@ phase
('LazyCircus.Testing.Bdd.Tg.userSends' addressed through
'dialogMovesToThread' \/ 'dialogReturnsToMainChat') feeds forum-topic updates
(a @message_thread_id@ payload with a forum-super-group chat, built by
'LazyCircus.Testing.Updates.mkTextUpdateByUserInThread'), and the @Then@ phase
asserts where the replies went ('LazyCircus.Testing.Bdd.Tg.botRepliesInThread'
\/ 'LazyCircus.Testing.Bdd.Tg.botRepliesInMainThread' over the journaled
'ObsTgMessage' 'obsThreadId' — recorded by the mocked performer from the send
request).

Everything runs with the database switched off, exactly as
"Bdd.EchoSmokeSpec" (a 'TestSupport.DbFreeApp.mkDbFreeApp' fixture whose pool
never allocates; Mocked Telegram mode captures every send).

Coverage: (1) a round trip through a topic and back to the main chat; (2) the
thread SURVIVES an actor switch ('memberTakesStage' does not move the chat)
and an @And@-continuation (it survives every 'awaitObservation'); (3) the
prefix marks topic posts in the reply text itself.
-}
module Bdd.ThreadSpec (spec) where

import LazyCircus (tgScript)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.App.Service (NoServiceLib)
import LazyCircus.Scenario (ScenarioProgram, evalScript)
import LazyCircus.Scene.Telegram.Lang qualified as Tg (sendMessage)
import LazyCircus.Script (Script)
import LazyCircus.Testing.Bdd.Gherkin (GherkinKeyword (..), GherkinScenario (..), GherkinStep (..))
import LazyCircus.Testing.Bdd.Journal (Observation (..))
import LazyCircus.Testing.Bdd.Pattern (Pattern, matchAll)
import LazyCircus.Testing.Bdd.Runner
    ( FeatureSource (..)
    , ScenarioRegistry
    , ScenarioVerifier
    , expectScenarioSuccess
    , gherkinSpec
    )
import LazyCircus.Testing.Bdd.Step (givenDef, mkRegistry)
import LazyCircus.Testing.Bdd.Tg
    ( botRepliesInMainThread
    , botRepliesInThread
    , botRepliesWithMessage
    , defaultUserTakesStage
    , dialogMovesToThread
    , dialogReturnsToMainChat
    , memberTakesStage
    , tgTestBootstrap
    , userSends
    )
import LazyCircus.Testing.Performer
    ( Mocks
    , TestConfig
    , runScenarioProgram
    , runWithConfig
    )
import LazyCircus.Testing.TgTest (TelegramTestScript, defaultTgTestConfig)
import Data.Text qualified as T
import RIO
import Telegram.Bot.API
    ( ChatId
    , Message
    , SomeChatId (..)
    , Update
    , defSendMessage
    , messageIsTopicMessage
    , messageMessageThreadId
    , messageText
    , sendMessageMessageThreadId
    , updateMessage
    )
import Telegram.Bot.API.GettingUpdates (updateChatId)
import Test.Hspec
import TestSupport.DbFreeApp (mkDbFreeApp)

--------------------------------------------------------------------------------
-- The spec tree
--------------------------------------------------------------------------------

-- | The vertical acceptance: the thread feature runs embedded in this tree
-- (the runner's coverage meta-test and ambiguity probe are part of it).
spec :: Spec
spec = do
    app <- runIO (mkDbFreeApp "thread-echo-bot")
    describe "Thread smoke (feature -> gherkinSpec -> thread-echo-bot, no PostgreSQL)" $ do
        gherkinSpec
            (FeatureInline "thread feature" threadEchoFeature)
            (\_ -> pure threadEchoRegistry)
            (tgTestBootstrap defaultTgTestConfig (buildThreadEchoAction app))
            threadEchoVerifier

--------------------------------------------------------------------------------
-- The thread feature and its registry
--------------------------------------------------------------------------------

-- | The smoke's feature document: a round trip into a topic and back, and a
-- topic dialog that switches actors mid-thread (the thread must survive the
-- actor switch and every reply-consuming await).
threadEchoFeature :: Text
threadEchoFeature =
    T.unlines
        [ "Feature: Forum-thread dialog"
        , "  Scenario: the dialog moves into a forum thread and back"
        , "    Given the thread-echo bot is awake"
        , "    When the user sends \"hello\""
        , "    Then the bot replies with \"hello\""
        , "    And the bot replies in the main chat"
        , "    When the dialog moves to the thread \"42\""
        , "    And the user sends \"into the topic\""
        , "    Then the bot replies with \"[topic] into the topic\""
        , "    And the bot replies in the thread \"42\""
        , "    When the dialog returns to the main chat"
        , "    And the user sends \"back to main\""
        , "    Then the bot replies with \"back to main\""
        , "    And the bot replies in the main chat"
        , ""
        , "  Scenario: the thread survives an actor switch and an And-continuation"
        , "    Given the thread-echo bot is awake"
        , "    When the dialog moves to the thread \"7\""
        , "    And the member \"@carol\" takes the stage"
        , "    And the user sends \"carol here\""
        , "    Then the bot replies with \"[topic] carol here\""
        , "    And the bot replies in the thread \"7\""
        , "    When the default user takes the stage"
        , "    And the user sends \"default here\""
        , "    Then the bot replies with \"[topic] default here\""
        , "    And the bot replies in the thread \"7\""
        , "    When the dialog returns to the main chat"
        , "    And the user sends \"back to main\""
        , "    Then the bot replies with \"back to main\""
        , "    And the bot replies in the main chat"
        ]

-- | The STATIC thread registry, shared by every scenario of the feature: the
-- Given is a no-op (the bootstrap wires the bot), every input verb is the
-- LIBRARY 'userSends' (it addresses the state's acting user AND active
-- thread), and the reply Then-constructors read their expected values from
-- their own captures.
threadEchoRegistry :: ScenarioRegistry NoServiceLib () TelegramTestScript
threadEchoRegistry = mkRegistry
    [ givenDef "the thread-echo bot is awake" (\_params -> pure . id)
    , userSends
    , memberTakesStage
    , defaultUserTakesStage
    , dialogMovesToThread
    , dialogReturnsToMainChat
    , botRepliesWithMessage
    , botRepliesInThread
    , botRepliesInMainThread
    ]

-- | The @Then@ pattern of the exact-reply constructor: the quoted span is the
-- expected reply text. Named here so the verifier counts reply steps by the
-- same pattern the registry routes them by.
repliesPattern :: Pattern
repliesPattern = "the bot replies with \"$text\""

-- | Verifier: the scenario ran to success and the journal holds exactly one
-- bot-message observation per reply-consuming step of the scenario — and
-- nothing else (the reply texts and their locations are already asserted by
-- the reply steps and their location And-continuations).
threadEchoVerifier :: ScenarioVerifier ()
threadEchoVerifier scenario outcome observations = do
    expectScenarioSuccess scenario outcome observations
    let expected = length
            [ ()
            | step <- gherkinScenarioSteps scenario
            , gherkinStepKeyword step == ThenKeyword
            , matchAll [("reply exact", repliesPattern)] (gherkinStepText step) == ["reply exact"]
            ]
        isReply ObsTgMessage{} = True
        isReply _ = False
    unless (length observations == expected && all isReply observations) $
        expectationFailure $
            "expected exactly " <> show expected
                <> " journaled bot message(s), got: " <> show observations

--------------------------------------------------------------------------------
-- Bootstrap: the DB-free thread-echo app under the canonical tgTest driver
--------------------------------------------------------------------------------

-- | The thread-echo bot's buildAction (the 'Bdd.EchoSmokeSpec.buildEchoAction'
-- shape): text updates are echoed back to their chat — mirrored thread id,
-- @[topic]@ prefix when the message reports itself as a topic post.
-- PRE-CONTRACT: @mocks@ must be the 'Mocks' set the executor wired the
-- runtime with (the runner-owned ones), so the echo's outgoing messages land
-- in the observed mailbox\/journal.
buildThreadEchoAction
    :: DefaultApp NoServiceLib
    -> TestConfig ()
    -> Mocks NoServiceLib
    -> IO (Update -> IO ())
buildThreadEchoAction app cfg mocks =
    pure $ \update ->
        case updateChatId update of
            Nothing -> pure ()
            Just chatId -> case updateMessage update of
                Nothing -> pure ()
                Just msg -> case messageText msg of
                    Just txt ->
                        runWithConfig app cfg mocks (runScenarioProgram (threadEchoScenario chatId msg txt))
                    Nothing -> pure ()

-- | The thread-echo scenario: replies to @chatId@ with the incoming text,
-- sent to the SAME topic the message arrived in (the reply's
-- @sendMessageMessageThreadId@ mirrors @messageMessageThreadId@) and prefixed
-- with @[topic]@ when the incoming message reports @is_topic_message@.
threadEchoScenario :: ChatId -> Message -> Text -> ScenarioProgram Script NoServiceLib ()
threadEchoScenario chatId msg txt =
    void $
        evalScript $
            tgScript "thread-echo-bot" $
                Tg.sendMessage
                    (defSendMessage (SomeChatId chatId) reply)
                        { sendMessageMessageThreadId = messageMessageThreadId msg }
  where
    -- | The reply text: the @[topic]@ prefix marks a topic post so the thread
    -- path is visible in the asserted text too.
    reply
        | messageIsTopicMessage msg == Just True = "[topic] " <> txt
        | otherwise = txt
