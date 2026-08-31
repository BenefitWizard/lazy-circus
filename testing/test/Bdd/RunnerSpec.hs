{-# LANGUAGE OverloadedStrings #-}

{- | Synthetic integration tests for the hspec BDD runner
('LazyCircus.Testing.Bdd.Runner.gherkinSpec') — plan task T11.

Everything here runs WITHOUT PostgreSQL:

  * the plain-IO suites drive the runner through a plain 'IO' executor —
    no application at all;
  * the test-performer suite backs the performer with 'echoApp', a
    hand-built 'LazyCircus.App.Default.DefaultApp' whose pool create action
    is 'fail' — 'newDefaultApp' cannot be used because it probes its pool
    (and therefore the database) eagerly at construction, while this spec
must pass with the database switched off.

Coverage: a green inline feature builds the describe\/it tree and
passes; an undefined step fails the coverage meta-test with a single
@feature \/ scenario \/ line \/ step text@ listing; a @\@blocked@ scenario
is skipped visibly instead of failing; every @Scenario Outline:@ row
becomes its own @it@ with the substituted name; a genuinely ambiguous
registry (two same-phase patterns on one step text) keeps the tree green
while the ambiguity probe's captured report names both colliding
patterns; and the canonical
test-performer wiring ('LazyCircus.Testing.Performer.runWithConfig' with
the fresh journal injected via @tcJournal@) records observations that the
post-scenario verifier reads back from the journal snapshot.
-}
module Bdd.RunnerSpec (spec) where

import Crypto.JOSE (KeyMaterialGenParam (OctGenParam), genJWK)
import Data.Pool (defaultPoolConfig, newPool)
import Database.PostgreSQL.Simple (close)
import Data.Text qualified as T
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import LazyCircus.App.Default (DefaultApp (..), MailCreds (..))
import LazyCircus.App.Service (NoServiceLib (..), ToolCallExec (..))
import LazyCircus.Testing.Bdd.Given (AppContext)
import LazyCircus.Testing.Bdd.Journal
    ( Observation (..)
    , ObservationLog
    , ScenarioState (..)
    , appendObservation
    )
import LazyCircus.Testing.Bdd.Runner
import LazyCircus.Testing.Bdd.Step (StepRegistry, givenDef, mkRegistry, thenDef, whenDef)
import LazyCircus.Testing.Performer
    ( Mocks
    , TestConfig (..)
    , TestInterpreter
    , defaultTestConfig
    , runWithConfig
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
import Test.Hspec
import Test.Hspec.Runner (Summary (..), defaultConfig, hspecWithResult)

spec :: Spec
spec = describe "gherkinSpec (BDD runner)" $ do
    it "green inline feature builds the describe/it tree and passes" $ do
        (summary, report) <- runRunnerSpec (ioGherkinSpec greenFeature)
        summaryExamples summary `shouldBe` 3
        summaryFailures summary `shouldBe` 0
        report `shouldSatisfy` T.isInfixOf "inline feature"
        report `shouldSatisfy` T.isInfixOf "greets the user"
        report `shouldSatisfy` T.isInfixOf metaCoverageExampleName
        report `shouldSatisfy` T.isInfixOf ambiguityProbeExampleName
        -- the meta-test runs BEFORE any scenario example
        let (_, afterMeta) = T.breakOn metaCoverageExampleName report
        afterMeta `shouldSatisfy` T.isInfixOf "greets the user"

    it "a feature with an undefined step fails the meta-test listing feature/scenario/line/text" $ do
        (summary, report) <- runRunnerSpec (ioGherkinSpec undefinedStepFeature)
        summaryFailures summary `shouldSatisfy` (> 0)
        report `shouldSatisfy` T.isInfixOf "BDD coverage meta-test failed"
        report
            `shouldSatisfy` T.isInfixOf
                "inline feature / has an undefined step / line 3 / nothing is prepared"

    it "an @blocked scenario is skipped visibly (pending), not failed" $ do
        (summary, report) <- runRunnerSpec (ioGherkinSpec blockedFeature)
        summaryExamples summary `shouldBe` 4
        summaryFailures summary `shouldBe` 0
        report `shouldSatisfy` T.isInfixOf "not implemented yet"
        report `shouldSatisfy` T.isInfixOf "works already"
        -- visible skip: the blocked scenario is not rendered as a success
        report `shouldNotSatisfy` T.isInfixOf "not implemented yet [✓]"

    it "every outline row becomes its own it with the substituted name" $ do
        (summary, report) <- runRunnerSpec (ioGherkinSpec outlineFeature)
        summaryExamples summary `shouldBe` 4
        summaryFailures summary `shouldBe` 0
        report `shouldSatisfy` T.isInfixOf "echoes the word alpha"
        report `shouldSatisfy` T.isInfixOf "echoes the word beta"

    it "the ambiguity probe reports both colliding same-phase patterns and stays green" $ do
        (summary, report) <- runRunnerSpec (ambiguousGherkinSpec ambiguousFeature)
        -- meta-test + probe + one scenario
        summaryExamples summary `shouldBe` 3
        -- the probe is non-blocking: a genuinely ambiguous registry never
        -- fails the tree (the scenario itself runs first-match-wins)
        summaryFailures summary `shouldBe` 0
        -- the captured report names the step, the match count and BOTH
        -- colliding Then patterns, in registration order
        report
            `shouldSatisfy` T.isInfixOf
                ( "ambiguous feature / colliding replies / line 5 / the bot replies with \"hello\""
                    <> " is matched by 2 same-phase patterns"
                    <> ": 'the bot replies with \"msg\"', 'the bot replies \"what\"'"
                )

    it "test-performer wiring records journal observations the verifier reads back" $ do
        (summary, report) <- runRunnerSpec performerSpec
        summaryFailures summary `shouldBe` 0
        report `shouldSatisfy` T.isInfixOf "the bot answers"

--------------------------------------------------------------------------------
-- Plain-IO suites (no application, no mocks)
--------------------------------------------------------------------------------

-- | Binds the echo registry, the plain-IO bootstrap and the echo verifier
-- into one runner spec for an inline feature.
ioGherkinSpec :: Text -> Spec
ioGherkinSpec source =
    gherkinSpec
        (FeatureInline "inline feature" source)
        (\_scenario -> pure ioRegistry)
        ioBootstrap
        echoVerifier

-- | Binds the ambiguous registry, the plain-IO bootstrap and the echo
-- verifier into one runner spec for an inline feature.
ambiguousGherkinSpec :: Text -> Spec
ambiguousGherkinSpec source =
    gherkinSpec
        (FeatureInline "ambiguous feature" source)
        (\_scenario -> pure ambiguousRegistry)
        ioBootstrap
        echoVerifier

-- | Echo-style registry: every recognized step passes the dialog through
-- untouched; the captured parameter is never inspected (the T12 stack).
ioRegistry :: ScenarioRegistry NoServiceLib () IO
ioRegistry = mkRegistry
    [ givenDef "the echo bot is awake" (\ctx -> pure ctx)
    , whenDef "the user sends \"msg\"" (\st -> pure (st, Nothing))
    , thenDef "the bot replies with \"msg\"" (\st -> pure (st, Nothing))
    ]

-- | Ambiguous registry: two Then patterns that both match the same step
-- text (the ambiguity-probe fodder); first-match-wins keeps scenarios green.
ambiguousRegistry :: ScenarioRegistry NoServiceLib () IO
ambiguousRegistry = mkRegistry
    [ givenDef "the echo bot is awake" (\ctx -> pure ctx)
    , whenDef "the user sends \"msg\"" (\st -> pure (st, Nothing))
    , thenDef "the bot replies with \"msg\"" (\st -> pure (st, Nothing))
    , thenDef "the bot replies \"what\"" (\st -> pure (st, Nothing))
    ]

-- | Plain-IO executor: the prepared step program already is an 'IO' action.
ioBootstrap :: ScenarioBootstrap NoServiceLib () IO
ioBootstrap _journal _mocks = pure id

-- | Echo verifier: the pilot run must succeed and echo scenarios produce no
-- journal observations.
echoVerifier :: ScenarioVerifier ()
echoVerifier scenario outcome observations = do
    expectScenarioSuccess scenario outcome observations
    observations `shouldBe` []

-- | A green Given\/When\/Then dialog.
greenFeature :: Text
greenFeature =
    T.unlines
        [ "Feature: Echo dialog"
        , "  Scenario: greets the user"
        , "    Given the echo bot is awake"
        , "    When the user sends \"hello\""
        , "    Then the bot replies with \"hello\""
        ]

-- | A feature whose Given step has no registry entry (meta-test fodder).
undefinedStepFeature :: Text
undefinedStepFeature =
    T.unlines
        [ "Feature: Broken coverage"
        , "  Scenario: has an undefined step"
        , "    Given nothing is prepared"
        , "    When the user sends \"hi\""
        , "    Then the bot replies with \"hi\""
        ]

-- | A blocked scenario next to a working one.
blockedFeature :: Text
blockedFeature =
    T.unlines
        [ "Feature: Partial delivery"
        , "  @blocked"
        , "  Scenario: not implemented yet"
        , "    Given the echo bot is awake"
        , "    When the user sends \"hi\""
        , "    Then the bot replies with \"hi\""
        , ""
        , "  Scenario: works already"
        , "    Given the echo bot is awake"
        , "    When the user sends \"done\""
        , "    Then the bot replies with \"done\""
        ]

-- | An outline with two example rows.
outlineFeature :: Text
outlineFeature =
    T.unlines
        [ "Feature: Outline expansion"
        , "  Scenario Outline: echoes the word <word>"
        , "    Given the echo bot is awake"
        , "    When the user sends \"<word>\""
        , "    Then the bot replies with \"<word>\""
        , ""
    , "    Examples:"
    , "      | word  |"
    , "      | alpha |"
    , "      | beta  |"
    ]

-- | A feature whose Then step text is matched by two registered Then
-- patterns of the ambiguous registry.
ambiguousFeature :: Text
ambiguousFeature =
    T.unlines
        [ "Feature: Ambiguous registration"
        , "  Scenario: colliding replies"
        , "    Given the echo bot is awake"
        , "    When the user sends \"hello\""
        , "    Then the bot replies with \"hello\""
        ]

--------------------------------------------------------------------------------
-- Test-performer suite (canonical wiring, database-free app)
--------------------------------------------------------------------------------

performerSpec :: Spec
performerSpec =
    gherkinSpec
        (FeatureInline "performer feature" greenFeature')
        (\_scenario -> pure performerRegistry)
        performerBootstrap
        performerVerifier
  where
    -- | Renamed copy so the performer run is identifiable in the report.
    greenFeature' =
        T.replace "greets the user" "the bot answers" greenFeature

-- | Performer-path registry: the When step records one app observation in
-- the scenario's journal (read through 'ScenarioState').
performerRegistry :: MonadIO m => StepRegistry m (AppContext ()) (ScenarioState ()) ()
performerRegistry = mkRegistry
    [ givenDef "the echo bot is awake" (\ctx -> pure ctx)
    , whenDef "the user sends \"msg\"" (\st -> do
            liftIO (atomically (appendObservation (ssLog st) (ObsApp ())))
            pure (st, Nothing))
    , thenDef "the bot replies with \"msg\"" (\st -> pure (st, Nothing))
    ]

-- | Canonical app wiring under the test performer (the documented
-- 'ScenarioBootstrap' shape): the fresh journal rides in via @tcJournal@ and
-- the DB-free 'echoApp' backs the performer environment.
performerBootstrap
    :: ObservationLog ()
    -> Mocks NoServiceLib
    -> IO (TestInterpreter NoServiceLib () (ScenarioOutcome ()) -> IO (ScenarioOutcome ()))
performerBootstrap journal mocks = do
    app <- echoApp
    let config = defaultTestConfig{tcJournal = Just journal}
    pure (\program -> runWithConfig app config mocks program)

-- | Performer verifier: the run succeeds and the journal snapshot contains
-- exactly the observation the When step recorded.
performerVerifier :: ScenarioVerifier ()
performerVerifier scenario outcome observations = do
    expectScenarioSuccess scenario outcome observations
    observations `shouldBe` [ObsApp ()]

-- | A 'DefaultApp' that never contacts PostgreSQL: the pool create action is
-- 'fail', so any accidental checkout throws instead of connecting.
-- 'newDefaultApp' cannot be used here — it probes its pool eagerly at
-- construction and would reach for the database.
echoApp :: IO (DefaultApp NoServiceLib)
echoApp = do
    pgPool <-
        newPool
            ( defaultPoolConfig
                (fail "Bdd.RunnerSpec: the DB pool must never be checked out")
                close
                30
                1
            )
    logQueueVal <- newTQueueIO
    asyncTasksVal <- newTQueueIO
    manager <- newTlsManager
    jwk <- genJWK (OctGenParam 256)
    processCtx <- mkDefaultProcessContext
    aiEnv <- getClientEnv "http://127.0.0.1:1"
    pure App
        { logFunc = mkLogFunc (\_ _ _ _ -> pure ())
        , genLogFunc = mkGLogFunc (\_ _ -> pure ())
        , pgDbPool = pgPool
        , pgDbPoolReadOnly = Nothing
        , appProcessContext = processCtx
        , botEnvs = M.empty
        , jwtSettings = defaultJWTSettings jwk
        , logQueue = logQueueVal
        , extraContext = HM.empty
        , logContext = mempty
        , mailCreds =
            MailCreds
                { mailHost = "localhost"
                , mailPort = 2525
                , mailLogin = ""
                , mailPassword = ""
                , mailName = "echo"
                , mailUseTls = False
                }
        , asyncTasks = asyncTasksVal
        , aiMethods = makeMethods aiEnv "not-configured" Nothing Nothing
        , sqlLogAction = \_ -> pure ()
        , serviceLib = NoServiceLib
        , appToolDescriptions = []
        , toolCallExec = ToolCallExec (\_ _ -> fail "Bdd.RunnerSpec: no tool execution")
        , httpManager = manager
        }

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
    (path, hTmp) <- openTempFile tmpDir "bdd-runner-spec.log"
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
