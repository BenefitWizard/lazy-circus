{-# LANGUAGE OverloadedStrings #-}

{- | Echo-smoke vertical acceptance for the BDD stack: a full
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
spec tree); the STATIC registry (one shared value for every scenario) reuses
the library Telegram @Then@-dictionary
('LazyCircus.Testing.Bdd.Tg.botRepliesWithMessage' +
'LazyCircus.Testing.Bdd.Tg.botReplyContains' as the @And@-continuation); the
@When@ step sends the user's words through the canonical @tgTest@ driver —
'LazyCircus.Testing.TgTest.sendMessage' feeds a fake update into the headless
bot whose buildAction runs the echo scenario (a @ScenarioProgram@ that
@sendTo@s the incoming text back) under
'LazyCircus.Testing.Performer.runWithConfig' with the scenario's fresh
observation journal injected via @tcJournal@.

Executor note: the registry monad is 'LazyCircus.Testing.TgTest.TelegramTestScript'
(the library Then-constructors' dialog monad), so the bootstrap is the
library-provided 'LazyCircus.Testing.Bdd.Tg.tgTestBootstrap': the scenario
runs via 'LazyCircus.Testing.TgTest.tgTestWithMocks' over the RUNNER-OWNED
'LazyCircus.Testing.Performer.Mocks' — the same fresh set the runner wires
into the Given phase ('LazyCircus.Testing.Bdd.Given.appContextFor'), so
Given-phase staging (a canned download) is visible to the headless bot; the
journal, wired via @tcJournal@, is the observation channel the Then steps and
the verifier read.

Coverage: (1) a green dialog round trip; (2) @And@-continuation reuse over the
consumed reply; (3) a @\@blocked@ scenario skipped visibly (pending) whose
steps the meta-test still requires to be registered; (4) an undefined step
failing the meta-test with the @feature / scenario / line / step text@
listing; (5) a When\/Then pattern repeated at two different values in a
single scenario (the static-registry regression); (6) a Given-staged download
flowing through the bot's download scene and answered with a deterministic
byte-length reply.
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
import LazyCircus.Scene.Telegram.Lang qualified as Tg (downloadFileById, sendMessage)
import LazyCircus.Script (Script)
import LazyCircus.Telegram (makeBotEnv)
import LazyCircus.Testing.Bdd.Gherkin (GherkinKeyword (..), GherkinScenario (..), GherkinStep (..))
import LazyCircus.Testing.Bdd.Given (stagedTgDownloads)
import LazyCircus.Testing.Bdd.Journal (Observation (..))
import LazyCircus.Testing.Bdd.Pattern (Pattern, lookupParam, matchAll)
import LazyCircus.Testing.Bdd.Runner
    ( FeatureSource (..)
    , ScenarioRegistry
    , ScenarioVerifier
    , expectScenarioSuccess
    , gherkinSpec
    )
import LazyCircus.Testing.Bdd.Step (givenDef, mkRegistry, whenDef)
import LazyCircus.Testing.Bdd.Tg (botReplyContains, botRepliesWithMessage, tgTestBootstrap)
import LazyCircus.Testing.Performer
    ( Mocks
    , TestConfig
    , runScenarioProgram
    , runWithConfig
    )
import LazyCircus.Testing.TgTest
    ( TelegramTestScript
    , defaultTgTestConfig
    , sendDocumentAs
    , sendMessage
    )
import Network.HTTP.Client.TLS (newTlsManager)
import OpenAI.V1 (getClientEnv, makeMethods)
import RIO
import RIO.ByteString qualified as BS
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
    , documentFileId
    , messageDocument
    , messageText
    , updateMessage
    )
import Telegram.Bot.API.GettingUpdates (updateChatId)
import Telegram.Bot.API.Types (FileId (..))
import Test.Hspec
import TestSupport.DbFreeApp (mkDbFreeApp)
import Test.Hspec.Runner (Summary (..), defaultConfig, hspecWithResult)

--------------------------------------------------------------------------------
-- The spec tree
--------------------------------------------------------------------------------

-- | The vertical acceptance: the echo feature runs embedded in this tree
-- (so the runner's meta-test and ambiguity probe are part of it), and the
-- undefined-step failure is asserted as a captured child run.
spec :: Spec
spec = do
    app <- runIO (mkDbFreeApp "echo-bot")
    describe "Echo smoke (feature -> gherkinSpec -> echo-bot, no PostgreSQL)" $ do
        gherkinSpec
            (FeatureInline "echo feature" echoFeature)
            (\_ -> pure echoRegistry)
            (tgTestBootstrap defaultTgTestConfig (buildEchoAction app))
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
-- re-using the consumed reply, a repeated When\/Then pattern at two different
-- values (the static-registry regression), a Given-staged download answered
-- with its byte length, and a @\@blocked@ scenario (skipped visibly; its
-- steps must still be registered for the meta-test).
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
        , "  Scenario: echoes twice with different words"
        , "    Given the echo bot is awake"
        , "    When the user sends \"one\""
        , "    Then the bot replies with \"one\""
        , "    When the user sends \"two\""
        , "    Then the bot replies with \"two\""
        , ""
        , "  Scenario: replies with the staged file size"
        , "    Given file \"doc-1\" is downloadable"
        , "    When the user uploads document \"doc-1\""
        , "    Then the bot replies with \"" <> stagedReply <> "\""
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
whenPattern :: Pattern
whenPattern = "the user sends \"$msg\""

-- | The @And@-continuation pattern: the quoted span is the asserted fragment
-- of the last consumed reply.
containsPattern :: Pattern
containsPattern = "the bot replies with a message containing \"$frag\""

-- | The @Then@ pattern of the exact-reply constructor: the quoted span is the
-- expected reply text. Named here so the verifier counts reply steps by the
-- same pattern the registry routes them by.
repliesPattern :: Pattern
repliesPattern = "the bot replies with \"$text\""

-- | The @Given@ pattern of the download staging: the quoted span is the
-- 'FileId' the canned bytes are staged under.
downloadPattern :: Pattern
downloadPattern = "file \"$name\" is downloadable"

-- | The @When@ pattern of the document upload: the quoted span is the 'FileId'
-- the upload update carries (a metadata-free upload — no @message.text@).
uploadPattern :: Pattern
uploadPattern = "the user uploads document \"$file\""

-- | The canned bytes the download @Given@ stages: short and fixed, so the
-- byte length the document branch replies with is a stable expected value.
stagedBytes :: ByteString
stagedBytes = "bdd staged bytes"

-- | The deterministic reply the document branch derives from the staged
-- bytes — spliced into the feature's @Then@ so feature text and registry
-- staging stay in sync by construction.
stagedReply :: Text
stagedReply = T.pack (show (BS.length stagedBytes))

-- | The STATIC echo registry, shared by every scenario of the feature: no
-- value is baked in at registration time — the Given staging def keys the
-- canned bytes off its own capture, the @When@ actions read the user's words
-- / upload target from the matched step's own captures, and the library
-- Then-constructors read their expected values from their own captures.
--
-- Selection is deterministic by rule, not by registration order:
-- 'matchingDefs' picks a 'Literal' match first, then templates in
-- registration order; the two reply templates here no longer overlap under
-- strict quoted captures, so each reply step has exactly one match.
echoRegistry :: ScenarioRegistry NoServiceLib () TelegramTestScript
echoRegistry = mkRegistry
    [ givenDef "the echo bot is awake" (\_params -> pure . id)
    , givenDef downloadPattern $
        \params ->
            stagedTgDownloads
                [(FileId (fromMaybe "doc-1" (lookupParam "$name" params)), stagedBytes)]
    , whenDef whenPattern $ \params st -> do
        _ <- sendMessage (fromMaybe "" (lookupParam "$msg" params))
        pure (st, Nothing)
    , whenDef uploadPattern $ \params st -> do
        _ <- sendDocumentAs (FileId (fromMaybe "doc-1" (lookupParam "$file" params))) Nothing Nothing Nothing
        pure (st, Nothing)
    , botReplyContains
    , botRepliesWithMessage
    ]

-- | The reply Then-dictionary of the registry, narrowest first — the same
-- order the library constructors are registered in, so the head of
-- 'matchAll' names the definition a first-match-wins registry routes to.
replyStepKinds :: [(Text, Pattern)]
replyStepKinds =
    [ ("reply contains", containsPattern)
    , ("reply exact", repliesPattern)
    ]

-- | Counts the bot replies a scenario consumes: its Then-resolved steps
-- routed to the exact-reply definition — each such step consumes exactly ONE
-- journaled 'ObsTgMessage'; the And-continuation re-inspects the last
-- consumed reply instead of consuming.
replyCount :: GherkinScenario -> Int
replyCount scenario = length
    [ ()
    | step <- gherkinScenarioSteps scenario
    , gherkinStepKeyword step == ThenKeyword
    , matchAll replyStepKinds (gherkinStepText step) == ["reply exact"]
    ]

-- | Verifier: the scenario ran to success and the journal holds exactly one
-- bot-message observation per Then-reply of the scenario — and nothing else
-- (the exact reply texts are already asserted by the reply-consuming Then
-- steps).
echoVerifier :: ScenarioVerifier ()
echoVerifier scenario outcome observations = do
    expectScenarioSuccess scenario outcome observations
    let expected = replyCount scenario
        isReply ObsTgMessage{} = True
        isReply _ = False
    unless (length observations == expected && all isReply observations) $
        expectationFailure $
            "expected exactly " <> show expected
                <> " journaled bot message(s), got: " <> show observations

--------------------------------------------------------------------------------
-- Bootstrap: the DB-free echo app under the canonical tgTest driver
--------------------------------------------------------------------------------

-- | The echo bot's buildAction (the 'TestHelpers.Bot.buildDemoAction' shape):
-- the production-style update driver with the test performer substituted —
-- text updates are echoed back to their chat, document updates download the
-- staged file by its 'FileId' through the Telegram download scene and reply
-- with the downloaded byte count.
-- PRE-CONTRACT: @mocks@ must be the 'Mocks' set the executor wired the
-- runtime with (the runner-owned ones), so the echo's outgoing messages land
-- in the observed mailbox\/journal AND the download scene reads the canned
-- bytes staged into those very mocks.
buildEchoAction
    :: DefaultApp NoServiceLib
    -> TestConfig ()
    -> Mocks NoServiceLib
    -> IO (Update -> IO ())
buildEchoAction app cfg mocks =
    pure $ \update ->
        case updateChatId update of
            Nothing -> pure ()
            Just chatId -> case updateMessage update of
                Nothing -> pure ()
                Just msg -> case messageText msg of
                    Just txt ->
                        runWithConfig app cfg mocks (runScenarioProgram (echoScenario chatId txt))
                    Nothing -> case messageDocument msg of
                        Just doc ->
                            runWithConfig app cfg mocks $
                                runScenarioProgram
                                    (documentEchoScenario chatId (documentFileId doc))
                        Nothing -> pure ()

-- | The document scenario: downloads the staged file by its 'FileId' and
-- replies with a deterministic text derived from the downloaded content —
-- its byte length (the text the feature's Then asserts).
documentEchoScenario :: ChatId -> FileId -> ScenarioProgram Script NoServiceLib ()
documentEchoScenario chatId fid = do
    (_resp, bytes) <- evalScript $ tgScript "echo-bot" $ Tg.downloadFileById fid
    void $
        evalScript $
            tgScript "echo-bot" $
                Tg.sendMessage $
                    defSendMessage (SomeChatId chatId) (T.pack (show (BS.length bytes)))

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
        (\_ -> pure echoRegistry)
        (tgTestBootstrap defaultTgTestConfig (buildEchoAction app))
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
