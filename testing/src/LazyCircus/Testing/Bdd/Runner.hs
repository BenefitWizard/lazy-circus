{- |
hspec runner for Gherkin-subset feature documents over the BDD step
interpreter (plan task T11). 'gherkinSpec' turns a 'FeatureSource' — a
@.feature@ file or an inline Gherkin document with a label — into a
self-contained hspec tree:

  * one @describe@ per feature document, labelled by its source label (the
    file path for 'FeatureFile', the caller's label for 'FeatureInline');
  * the coverage /meta-test/ example FIRST: it walks every step of every
    scenario and requires a registry match by resolved keyword + pattern.
    On gaps it fails ONCE, listing every uncovered step as
    @feature \/ scenario \/ line \/ step text@ (see 'metaCoverageExampleName');
  * the ambiguity /probe/ example SECOND: non-blocking (always green), it
    reports every pair of same-phase registry patterns that both match one
    of the feature's step texts (see 'ambiguityProbeExampleName');
  * one @it@ per scenario, in document order. @Scenario Outline:@ rows are
    already expanded by 'LazyCircus.Testing.Bdd.Gherkin.parseFeature', so
    every row becomes its own @it@ carrying the substituted name;
  * a scenario tagged @\@blocked@ never runs: it is skipped visibly with
    'pendingWith' (the meta-test still requires its steps to be registered,
    so the registry stays honest for the day the scenario unblocks).

Isolation mirrors the @tgTest@ pattern: EVERY executed scenario gets a fresh
'LazyCircus.Testing.Bdd.Journal.ObservationLog' and a fresh
'LazyCircus.Testing.Performer.Mocks' set — both handed to the
'ScenarioBootstrap', which wires them into the executor (the canonical app
wiring injects the fresh journal into
'LazyCircus.Testing.Performer.TestConfig' via @tcJournal@; see
'ScenarioBootstrap'). The scenario steps run in document order through
'LazyCircus.Testing.Bdd.Step.runScenarioSteps' on the canonical stack —
'LazyCircus.Testing.Bdd.Step.GivenDef' steps thread
'LazyCircus.Testing.Bdd.Given.AppContext' (seeded with 'appContextFor' over
the scenario's fresh mocks), When\/Then steps thread
'LazyCircus.Testing.Bdd.Journal.ScenarioState' (seeded with
'freshScenarioState' over the scenario's fresh journal). After the run the
runner snapshots the journal and hands the observations to the caller's
'ScenarioVerifier' for post-scenario (negative) checks.

The runner is GENERIC in the dialog monad @m@: the 'ScenarioBootstrap'
returns the executor that runs the prepared step program
('ScenarioExecutor'), so the same runner drives both the test-performer
stack (via 'LazyCircus.Testing.Performer.runWithConfig') and plain 'IO'
suites without any application at all.

KNOWN LIMITATION (failure attribution inside a running scenario): a failing
step surfaces only AFTER the pilot run, as a single
'LazyCircus.Testing.Bdd.Step.StepError' carrying scenario, line and text.
hspec therefore reports the failure at runner granularity — against the
scenario's own @it@, never against a per-step example. Follow-up: an
annotating combinator that projects the interpreter error into per-step spec
nodes is planned; until then, pinpoint the failing step via the
'LazyCircus.Testing.Bdd.Step.renderStepError' fields.

DB note: DB and HTTP sub-languages are always real under the test performer.
The runner itself never touches PostgreSQL — 'Bdd.RunnerSpec' shows a
database-free 'LazyCircus.App.Default.DefaultApp' construction for the
test-performer path.
-}
module LazyCircus.Testing.Bdd.Runner
    ( -- * Feature sources
      FeatureSource (..)
      -- * The runner
    , gherkinSpec
    , metaCoverageExampleName
    , ambiguityProbeExampleName
      -- * Seam types
    , ScenarioOutcome
    , ScenarioRegistry
    , ScenarioExecutor
    , ScenarioBootstrap
    , ScenarioVerifier
    , expectScenarioSuccess
    ) where

import LazyCircus.Testing.Bdd.Gherkin
import LazyCircus.Testing.Bdd.Given (AppContext, appContextFor)
import LazyCircus.Testing.Bdd.Journal
    ( Observation
    , ObservationLog
    , ScenarioState
    , freshScenarioState
    , newObservationLog
    , readObservations
    )
import LazyCircus.Testing.Bdd.Pattern (Pattern, matchStep)
import LazyCircus.Testing.Bdd.Step
    ( StepError
    , StepOutcome
    , StepRegistry (..)
    , renderStepError
    , runScenarioSteps
    , stepDefKeyword
    , stepDefPattern
    )
import LazyCircus.Testing.Performer (Mocks, makeMocks)
import RIO
import RIO.Text qualified as T
import System.IO qualified as SIO
import Test.Hspec

--------------------------------------------------------------------------------
-- Feature sources
--------------------------------------------------------------------------------

-- | Where the feature document comes from.
data FeatureSource
    = FeatureFile FilePath
      -- ^ read the document from a @.feature@ file; the file path doubles as
      -- the @describe@ label and as the @feature@ part of meta-test listings
    | FeatureInline Text Text
      -- ^ an inline Gherkin document together with its label (used the same
      -- way as the file path above)

-- | Loads a feature document together with its label.
-- POST-CONTRACT: 'Left' carries the parse error; 'Right' is the parsed
-- feature (outline rows already expanded). The label is returned either way
-- so the runner can always name the document.
loadFeature :: FeatureSource -> IO (Text, Either GherkinParseError GherkinFeature)
loadFeature source = case source of
    FeatureFile path -> do
        contents <- readFileUtf8 path
        pure (T.pack path, parseFeature contents)
    FeatureInline label contents -> pure (label, parseFeature contents)

--------------------------------------------------------------------------------
-- Seam types
--------------------------------------------------------------------------------

-- | Everything a verifier needs to know about one scenario's step run.
type ScenarioOutcome app =
    Either StepError (StepOutcome (AppContext app) (ScenarioState app) ())

-- | The canonical registry stack the runner drives: Given steps thread
-- 'LazyCircus.Testing.Bdd.Given.AppContext', When\/Then steps thread
-- 'LazyCircus.Testing.Bdd.Journal.ScenarioState'; emitted values are ignored
-- (use the journal for post-scenario assertions).
type ScenarioRegistry serviceLib app m =
    StepRegistry m (AppContext app) (ScenarioState app) ()

-- | Runs the prepared step program of one scenario to completion.
type ScenarioExecutor app m = m (ScenarioOutcome app) -> IO (ScenarioOutcome app)

-- | Builds the executor for ONE scenario, given that scenario's fresh
-- 'LazyCircus.Testing.Bdd.Journal.ObservationLog' and its fresh
-- 'LazyCircus.Testing.Performer.Mocks'.
--
-- FRESHNESS SEMANTICS: called once per EXECUTED scenario (a @\@blocked@
-- scenario never calls it). The app itself MAY be shared across scenarios —
-- build it once in the caller and close over it — per-scenario isolation is
-- guaranteed by the fresh journal + fresh mocks the runner allocates, never
-- by the bootstrap.
--
-- CANONICAL APP WIRING (test performer under an existing app):
--
-- > appBootstrap :: DefaultApp serviceLib
-- >              -> ObservationLog app
-- >              -> Mocks serviceLib
-- >              -> IO (ScenarioExecutor app (TestInterpreter serviceLib app))
-- > appBootstrap app journal mocks =
-- >     pure $ runWithConfig app defaultTestConfig{tcJournal = Just journal} mocks
--
-- The fresh journal travels to the performer via @tcJournal@ (the runner
-- OWNS journaling — every observation the performer intercepts lands in it);
-- the mocks are the same fresh set the runner used to seed the
-- 'LazyCircus.Testing.Bdd.Given.AppContext', so Given-phase staging and the
-- dialog share one mock state, exactly like a @tgTest@ run.
type ScenarioBootstrap serviceLib app m =
    ObservationLog app -> Mocks serviceLib -> IO (ScenarioExecutor app m)

-- | Post-scenario assertions: receives the scenario (name and tags), the
-- outcome of the step run, and the final journal snapshot in commit order.
-- The verifier is the single authority over scenario failures — the runner
-- itself never fails on a 'Left' outcome.
type ScenarioVerifier app =
    GherkinScenario -> ScenarioOutcome app -> [Observation app] -> IO ()

-- | Verifier prefix failing on an aborted step run.
-- POST-CONTRACT: Returns normally when every step of the scenario executed;
-- fails the enclosing example with the rendered 'StepError' otherwise.
expectScenarioSuccess :: ScenarioVerifier app
expectScenarioSuccess _scenario outcome _observations = case outcome of
    Left err -> expectationFailure (T.unpack (renderStepError err))
    Right _ -> pure ()

--------------------------------------------------------------------------------
-- The runner
--------------------------------------------------------------------------------

-- | hspec example name of the coverage meta-test (exported so callers can
-- filter or document it).
metaCoverageExampleName :: Text
metaCoverageExampleName = "coverage meta-test: every feature step matches a registered step definition (keyword + pattern)"

-- | hspec example name of the ambiguity probe (exported so callers can
-- filter or document it).
ambiguityProbeExampleName :: Text
ambiguityProbeExampleName = "ambiguity probe: same-phase registry patterns matching the same step text"

-- | Builds the hspec tree for one feature document.
--
-- REGISTRY FRESHNESS: the provider is invoked exactly once per scenario,
-- while the Spec is being constructed ('runIO'); the SAME resolved registry
-- is then used by the meta-test, the ambiguity probe and the scenario run.
-- Registries are treated as stateless values — cross-scenario isolation
-- comes from the fresh journal + fresh mocks, never from the provider. A
-- shared registry is expressed as @\\_ -> pure sharedRegistry@.
--
-- PRE-CONTRACT: For 'FeatureFile', the file must exist and be valid UTF-8.
-- POST-CONTRACT: The returned tree is @describe label [meta-test, ambiguity
-- probe, scenario its...]@ in that order — the meta-test runs before any
-- scenario example. A document that fails to parse produces a single failing
-- example carrying the label, the offending line and the parser's message.
gherkinSpec
    :: MonadIO m
    => FeatureSource
    -- ^ the feature document
    -> (GherkinScenario -> IO (ScenarioRegistry serviceLib app m))
    -- ^ step registry provider, called once per scenario (see freshness note)
    -> ScenarioBootstrap serviceLib app m
    -- ^ app bootstrap, called once per executed scenario with its fresh journal
    -> ScenarioVerifier app
    -- ^ post-scenario assertions over the outcome and the journal snapshot
    -> Spec
gherkinSpec source provider bootstrap verifier = do
    (label, parsed) <- runIO (loadFeature source)
    case parsed of
        Left err ->
            it (T.unpack label) $
                expectationFailure (T.unpack (renderParseFailure label err))
        Right feature -> describe (T.unpack label) $ do
            entries <- runIO (traverse resolveEntry (gherkinFeatureScenarios feature))
            it (T.unpack metaCoverageExampleName) (metaCoverageExample label entries)
            it (T.unpack ambiguityProbeExampleName) (ambiguityProbeExample label entries)
            forM_ entries $ \(scenario, registry) ->
                it (T.unpack (gherkinScenarioName scenario)) $
                    if "@blocked" `elem` gherkinScenarioTags scenario
                        then pendingWith "scenario is marked @blocked"
                        else runScenarioExample scenario registry
  where
    -- | Resolves the registry of one scenario.
    resolveEntry scenario = do
        registry <- provider scenario
        pure (scenario, registry)

    -- | Executes one scenario end to end: fresh journal, fresh mocks,
    -- bootstrap, document-order step run, journal snapshot, verifier.
    runScenarioExample scenario registry = do
        journal <- newObservationLog
        mocks <- makeMocks
        execute <- bootstrap journal mocks
        outcome <- execute $
            runScenarioSteps registry scenario (appContextFor mocks) (freshScenarioState journal)
        observations <- readObservations journal
        verifier scenario outcome observations

--------------------------------------------------------------------------------
-- Meta-test: coverage
--------------------------------------------------------------------------------

-- | The coverage meta-test body: ONE failure listing every uncovered step.
-- POST-CONTRACT: Fails the example when at least one feature step of the
-- feature has no registry entry matching by resolved keyword + pattern; the
-- message lists every such step as @feature \/ scenario \/ line \/ step text@.
metaCoverageExample :: Text -> [(GherkinScenario, ScenarioRegistry serviceLib app m)] -> IO ()
metaCoverageExample label entries =
    case concatMap (uncurry (scenarioUndefinedSteps label)) entries of
        [] -> pure ()
        uncovered ->
            expectationFailure $
                "BDD coverage meta-test failed: "
                    <> show (length uncovered)
                    <> " feature step(s) without a matching registry entry:\n"
                    <> T.unpack (T.intercalate "\n" uncovered)

-- | The uncovered steps of one scenario against its registry.
scenarioUndefinedSteps :: Text -> GherkinScenario -> ScenarioRegistry serviceLib app m -> [Text]
scenarioUndefinedSteps label scenario registry =
    [ renderUncoveredStep label scenario step
    | step <- gherkinScenarioSteps scenario
    , not (stepCovered registry step)
    ]

-- | Whether some registry definition covers a step by resolved keyword +
-- pattern (the same discipline 'LazyCircus.Testing.Bdd.Step.runScenarioSteps'
-- applies when selecting a definition).
stepCovered :: ScenarioRegistry serviceLib app m -> GherkinStep -> Bool
stepCovered registry step = any matches (registryStepDefs registry)
  where
    -- | A definition covers the step when its phase keyword equals the step's
    -- resolved keyword and its pattern matches the step text.
    matches def =
        stepDefKeyword def == gherkinStepKeyword step
            && isJust (matchStep (stepDefPattern def) (gherkinStepText step))

-- | Renders one uncovered step as @feature \/ scenario \/ line \/ step text@.
renderUncoveredStep :: Text -> GherkinScenario -> GherkinStep -> Text
renderUncoveredStep label scenario step =
    label
        <> " / "
        <> gherkinScenarioName scenario
        <> " / line "
        <> tshow (gherkinStepLine step)
        <> " / "
        <> gherkinStepText step

--------------------------------------------------------------------------------
-- Meta-test: ambiguity probe (non-blocking)
--------------------------------------------------------------------------------

-- | The ambiguity probe body: always green; prints a report line for every
-- feature step text matched by two or more same-phase registry patterns.
ambiguityProbeExample :: Text -> [(GherkinScenario, ScenarioRegistry serviceLib app m)] -> IO ()
ambiguityProbeExample label entries =
    case concatMap (uncurry (scenarioAmbiguities label)) entries of
        [] -> pure ()
        ambiguities -> SIO.hPutStr stdout (T.unpack (T.unlines ambiguities))

-- | The same-phase ambiguity reports of one scenario against its registry.
scenarioAmbiguities :: Text -> GherkinScenario -> ScenarioRegistry serviceLib app m -> [Text]
scenarioAmbiguities label scenario registry =
    [ renderAmbiguity label scenario step matches
    | step <- gherkinScenarioSteps scenario
    , let matches = samePhaseMatches registry step
    , length matches > 1
    ]

-- | Patterns of registry definitions in the step's own phase that match the
-- step text, in registration order.
samePhaseMatches :: ScenarioRegistry serviceLib app m -> GherkinStep -> [Pattern]
samePhaseMatches registry step =
    [ stepDefPattern def
    | def <- registryStepDefs registry
    , stepDefKeyword def == gherkinStepKeyword step
    , isJust (matchStep (stepDefPattern def) (gherkinStepText step))
    ]

-- | Renders one ambiguity report for a step matched by several patterns.
renderAmbiguity :: Text -> GherkinScenario -> GherkinStep -> [Pattern] -> Text
renderAmbiguity label scenario step patterns =
    renderUncoveredStep label scenario step
        <> " is matched by "
        <> tshow (length patterns)
        <> " same-phase patterns: "
        <> T.intercalate ", " (map (\pattern -> "'" <> pattern <> "'") patterns)

--------------------------------------------------------------------------------
-- Failure rendering
--------------------------------------------------------------------------------

-- | Renders a feature-document parse failure with its label.
renderParseFailure :: Text -> GherkinParseError -> Text
renderParseFailure label err =
    label
        <> ": failed to parse the feature document at line "
        <> tshow (gherkinParseErrorLine err)
        <> ": "
        <> renderGherkinParseError err
