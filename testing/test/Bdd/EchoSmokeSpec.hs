{-# LANGUAGE OverloadedStrings #-}

{- | Echo-smoke vertical acceptance for the BDD stack (plan task T12): a full
@.feature@ → 'gherkinSpec' → echo-bot round trip that NEVER contacts
PostgreSQL.

Everything runs with the database switched off:

  * the app is a hand-built 'LazyCircus.App.Default.DefaultApp' whose pool
    create action is 'fail' — 'newDefaultApp' cannot be used because it probes
    its pool (and therefore the database) EAGERLY at construction, while this
    smoke must pass with PostgreSQL stopped; the pool is never checked out
    because the echo scenario touches only the Telegram sub-language;
  * the Telegram bot environment (@echo-bot@) is built with
    'LazyCircus.Telegram.makeBotEnv', which performs no network I/O — in
    'LazyCircus.Testing.Performer.Mocked' mode every @sendMessage@ is captured
    instead of sent.

The round trip: the inline feature is turned into an hspec tree by
'gherkinSpec' (its coverage meta-test and ambiguity probe are part of THIS
spec tree); the registry reuses the library Telegram @Then@-dictionary
('LazyCircus.Testing.Bdd.Tg.botRepliesWithMessage' +
'LazyCircus.Testing.Bdd.Tg.botReplyContains' as the @And@-continuation); the
@When@ step sends the user's words through the canonical @tgTest@ driver —
'LazyCircus.Testing.TgTest.sendMessage' feeds a fake update into the headless
bot whose buildAction runs the echo scenario (a @ScenarioProgram@ that
@sendTo@s the incoming text back) under
'LazyCircus.Testing.Performer.runWithConfig' with the scenario's fresh
observation journal injected via @tcJournal@.

Executor note: the registry monad is 'LazyCircus.Testing.TgTest.TelegramTestScript'
(the library Then-constructors' dialog monad), so the 'ScenarioBootstrap'
executor is a 'LazyCircus.Testing.TgTest.tgTest' run — @tgTest@ allocates its
OWN fresh 'LazyCircus.Testing.Performer.Mocks' internally and hands them to
the buildAction; the runner-owned mocks stay unused (the smoke has no
Given-phase staging — the journal, shared via @tcJournal@, is the single
observation channel the Then steps and the verifier read).

Coverage: (1) a green dialog round trip; (2) @And@-continuation reuse over the
consumed reply; (3) a @\@blocked@ scenario skipped visibly (pending) whose
steps the meta-test still requires to be registered; (4) an undefined step
failing the meta-test with the @feature / scenario / line / step text@
listing.
-}
module Bdd.EchoSmokeSpec (spec) where

import Crypto.JOSE (KeyMaterialGenParam (OctGenParam), genJWK)
import Data.Pool (defaultPoolConfig, newPool)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (close)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import LazyCircus (tgScript)
import LazyCircus.App.Default (DefaultApp (..), MailCreds (..))
import LazyCircus.App.Service (NoServiceLib (..), ToolCallExec (..))
import LazyCircus.Scenario (ScenarioProgram, evalScript)
import LazyCircus.Scene.Telegram.Lang qualified as Tg (sendMessage)
import LazyCircus.Script (Script)
import LazyCircus.Telegram (makeBotEnv)
import LazyCircus.Testing.Bdd.Gherkin (GherkinScenario (..), GherkinStep (..))
import LazyCircus.Testing.Bdd.Journal (Observation (..))
import LazyCircus.Testing.Bdd.Pattern (matchStep)
import LazyCircus.Testing.Bdd.Runner
    ( FeatureSource (..)
    , ScenarioBootstrap
    , ScenarioRegistry
    , ScenarioVerifier
    , expectScenarioSuccess
    , gherkinSpec
    )
import LazyCircus.Testing.Bdd.Step (givenDef, mkRegistry, whenDef)
import LazyCircus.Testing.Bdd.Tg (botReplyContains, botRepliesWithMessage)
import LazyCircus.Testing.Performer
    ( Mocks
    , TestConfig (..)
    , defaultTestConfig
    , runScenarioProgram
    , runWithConfig
    )
import LazyCircus.Testing.TgTest
    ( TelegramTestScript
    , TgTestConfig (..)
    , defaultTgTestConfig
    , sendMessage
    , tgeDescription
    , tgTest
    )
import Network.HTTP.Client.TLS (newTlsManager)
import OpenAI.V1 (getClientEnv, makeMethods)
import RIO
import RIO.HashMap qualified as HM
import RIO.Map qualified as M
import RIO.Process (mkDefaultProcessContext)
import Servant.Auth.Server (defaultJWTSettings)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (openTempFile)
import Telegram.Bot.API
    ( ChatId
    , SomeChatId (..)
    , Token (..)
    , Update
    , defSendMessage
    , messageText
    , updateMessage
    )
import Telegram.Bot.API.GettingUpdates (updateChatId)
import Test.Hspec
import TestSupport.DbFreeApp (mkDbFreeApp)
import Test.Hspec.Runner (Summary (..), defaultConfig, hspecWithResult)

--------------------------------------------------------------------------------
-- The spec tree
--------------------------------------------------------------------------------

-- | The T12 vertical acceptance: the echo feature runs embedded in this tree
-- (so the runner's meta-test and ambiguity probe are part of it), and the
-- undefined-step failure is asserted as a captured child run.
spec :: Spec
spec = do
    app <- runIO (mkDbFreeApp "echo-bot")
    describe "Echo smoke (T12: feature -> gherkinSpec -> echo-bot, no PostgreSQL)" $ do
        gherkinSpec
            (FeatureInline "echo feature" echoFeature)
            (pure . echoRegistryFor)
            (echoBootstrap app)
            echoVerifier
        it "undefined step fails the meta-test listing feature/scenario/line/text" $ do
            (summary, report) <- runRunnerSpec (undefinedStepSpec app)
            summaryFailures summary `shouldSatisfy` (> 0)
            report `shouldSatisfy` T.isInfixOf "BDD coverage meta-test failed"
            report
                `shouldSatisfy` T.isInfixOf
                    "weather feature / chats about the weather / line 3 / the weather is lovely"

--------------------------------------------------------------------------------
-- The echo feature and its registry
--------------------------------------------------------------------------------

-- | The smoke's feature document: a green dialog, an @And@-continuation
-- re-using the consumed reply, and a @\@blocked@ scenario (skipped visibly;
-- its steps must still be registered for the meta-test).
echoFeature :: Text
echoFeature =
    T.unlines
        [ "Feature: Echo bot dialog"
        , "  Scenario: echoes the words of the user"
        , "    Given the echo bot is awake"
        , "    When the user sends \"hello, echo\""
        , "    Then the bot replies with \"hello, echo\""
        , ""
        , "  Scenario: reuses the reply in an And-continuation"
        , "    Given the echo bot is awake"
        , "    When the user sends \"the road is long\""
        , "    Then the bot replies with \"the road is long\""
        , "    And the bot replies with a message containing \"road\""
        , ""
        , "  @blocked"
        , "  Scenario: sings a lullaby (not implemented yet)"
        , "    Given the echo bot is awake"
        , "    When the user sends \"lullaby\""
        , "    Then the bot replies with \"lullaby\""
        ]

-- | A second, tiny feature whose Given step has no registry entry — the
-- meta-test failure listing is asserted in 'spec'.
undefinedStepFeature :: Text
undefinedStepFeature =
    T.unlines
        [ "Feature: Weather small talk"
        , "  Scenario: chats about the weather"
        , "    Given the weather is lovely"
        , "    When the user sends \"lovely weather\""
        , "    Then the bot replies with \"lovely weather\""
        ]

-- | The @When@ pattern of the echo registry: the quoted span is the user's
-- message.
whenPattern :: T.Text
whenPattern = "the user sends \"$msg\""

-- | The @And@-continuation pattern: the quoted span is the asserted fragment
-- of the last consumed reply.
containsPattern :: T.Text
containsPattern = "the bot replies with a message containing \"$frag\""

-- | The echo registry for ONE scenario: the values captured by the patterns
-- ($msg, $frag) are extracted from the scenario document with the library
-- matcher and baked into the step actions — step actions never see pattern
-- captures, exactly like the library Then-constructors bake their expected
-- text at registration time.
--
-- Registration order: 'botReplyContains' BEFORE 'botRepliesWithMessage' — the
-- catch-all capture of the latter would otherwise swallow the continuation's
-- step texts (first-registered-match-wins).
echoRegistryFor :: GherkinScenario -> ScenarioRegistry NoServiceLib () TelegramTestScript
echoRegistryFor scenario = mkRegistry $
    [ givenDef "the echo bot is awake" (pure . id)
    , whenDef whenPattern $ \st -> do
        _ <- sendMessage msg
        pure (st, Nothing)
    ]
        <> maybe [] (pure . botReplyContains) containsFrag
        <> [botRepliesWithMessage msg]
  where
    -- | The user's message captured from the scenario's When step.
    msg = fromMaybe "" (firstCapture whenPattern)
    -- | The fragment captured from the scenario's And-continuation, if any.
    containsFrag = firstCapture containsPattern
    -- | The first captured value of a pattern over the scenario's steps. A
    -- quoted span at the end of a pattern swallows the step's closing quote
    -- into the capture, so the surrounding quotes are stripped.
    firstCapture pattern = listToMaybe
        [ T.dropAround (== '"') value
        | step <- gherkinScenarioSteps scenario
        , Just params <- [matchStep pattern (gherkinStepText step)]
        , (_, value) <- take 1 params
        ]

-- | Verifier: the scenario ran to success and the journal holds exactly one
-- bot-message observation (the echo reply; its exact text is already asserted
-- by the reply-consuming Then step).
echoVerifier :: ScenarioVerifier ()
echoVerifier scenario outcome observations = do
    expectScenarioSuccess scenario outcome observations
    case observations of
        [ObsTgMessage{}] -> pure ()
        _ ->
            expectationFailure $
                "expected exactly one journaled bot message, got: " <> show observations

--------------------------------------------------------------------------------
-- Bootstrap: the DB-free echo app under the canonical tgTest driver
--------------------------------------------------------------------------------

-- | Builds the executor for one scenario: a 'tgTest' run whose performer
-- config carries the scenario's fresh journal (@tcJournal@, Telegram Mocked).
-- The journal is the single observation channel — the Then steps and the
-- verifier read it through 'LazyCircus.Testing.Bdd.Journal.ScenarioState' and
-- the snapshot respectively.
echoBootstrap :: DefaultApp NoServiceLib -> ScenarioBootstrap NoServiceLib () TelegramTestScript
echoBootstrap app journal _runnerMocks =
    pure $ \stepProgram -> do
        (_mailboxes, result) <- tgTest (tgTestConfig journal) (buildEchoAction app) stepProgram
        either (throwString . T.unpack . tgeDescription) pure result
  where
    -- | Run-level tgTest config with the fresh journal injected into the
    -- performer config (all sub-languages Mocked).
    tgTestConfig journal' =
        defaultTgTestConfig
            { ttgPerformerConfig = defaultTestConfig{tcJournal = Just journal'}
            }

-- | The echo bot's buildAction (the 'TestHelpers.Bot.buildDemoAction' shape):
-- the production-style update driver with the test performer substituted —
-- text updates are echoed back to their chat as a @ScenarioProgram@.
-- PRE-CONTRACT: @mocks@ must be the 'Mocks' set @tgTest@ wired the runtime
-- with, so the echo's outgoing messages land in the observed mailbox/journal.
buildEchoAction
    :: DefaultApp NoServiceLib
    -> TestConfig ()
    -> Mocks NoServiceLib
    -> IO (Update -> IO ())
buildEchoAction app cfg mocks =
    pure $ \update ->
        case (updateChatId update, updateMessage update >>= messageText) of
            (Just chatId, Just txt) ->
                runWithConfig app cfg mocks (runScenarioProgram (echoScenario chatId txt))
            _ -> pure ()

-- | The echo scenario: replies to @chatId@ with @txt@ as @echo-bot@.
echoScenario :: ChatId -> Text -> ScenarioProgram Script NoServiceLib ()
echoScenario chatId txt =
    void $
        evalScript $
            tgScript "echo-bot" $
                Tg.sendMessage (defSendMessage (SomeChatId chatId) txt)

-- | The child spec for the undefined-step smoke: same stack, feature whose
-- Given step is not in the registry.
undefinedStepSpec :: DefaultApp NoServiceLib -> Spec
undefinedStepSpec app =
    gherkinSpec
        (FeatureInline "weather feature" undefinedStepFeature)
        (pure . echoRegistryFor)
        (echoBootstrap app)
        echoVerifier

--------------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------------

-- | Runs a child spec with hspec while its report is captured into a temp
-- file under the system temp directory.
-- POST-CONTRACT: Returns the child run's summary and the full captured
-- report; the process' stdout is restored before returning.
runRunnerSpec :: Spec -> IO (Summary, Text)
runRunnerSpec childSpec = do
    tmpDir <- getTemporaryDirectory
    (path, hTmp) <- openTempFile tmpDir "bdd-echo-smoke-spec.log"
    realStdout <- hDuplicate stdout
    hDuplicateTo hTmp stdout
    summary <- hspecWithResult defaultConfig childSpec `finally` do
        hDuplicateTo realStdout stdout
        hClose realStdout
        hClose hTmp
    captured <- readFileUtf8 path
    removeFile path
    _ <- evaluate (T.length captured)
    pure (summary, captured)
