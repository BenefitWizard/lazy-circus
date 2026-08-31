{- |
Step definitions and a generic interpreter for already-expanded
'GherkinScenario's — the third layer of the BDD runner. 'parseFeature'
('LazyCircus.Testing.Bdd.Gherkin') produces scenarios, 'matchStep'
('LazyCircus.Testing.Bdd.Pattern') binds step texts to patterns, and this
module wires both together: a 'StepRegistry' collects 'StepDef's, and
'runScenarioSteps' executes a scenario's steps against it, threading a
context @c@ through Given steps and a dialog state @s@ through When\/Then
steps.

The interpreter is generic over the monad @m@ (only 'MonadIO' is required,
to lift the Given actions) and file-agnostic. Failure attribution works at
per-step granularity: a 'StepError' names the scenario, the failing step's
1-based line, its text and the reason, as a plain value — never an
exception. The runner adds feature\/file attribution at its own granularity.
-}
module LazyCircus.Testing.Bdd.Step
    ( -- * Step definitions
      StepDef (..)
    , stepDefKeyword
    , stepDefPattern
    , givenDef
    , whenDef
    , thenDef
      -- * Registry
    , StepRegistry (..)
    , emptyRegistry
    , mkRegistry
      -- * Interpretation
    , runScenarioSteps
    , StepRun (..)
    , StepOutcome (..)
      -- * Structural errors
    , StepError (..)
    , StepErrorReason (..)
    , renderStepError
    , renderStepErrorReason
    ) where

import LazyCircus.Testing.Bdd.Gherkin
import LazyCircus.Testing.Bdd.Pattern
import RIO

--------------------------------------------------------------------------------
-- Step definitions
--------------------------------------------------------------------------------

-- | One registered step definition.
--
-- Phase discipline: ALL Given steps of a scenario must precede the first
-- When\/Then step. 'GivenDef' accumulates the context @c@ and can neither see
-- nor change the dialog state @s@; 'DialogDef' (registered for When\/Then)
-- threads @s@ and may emit a value of type @a@. 'runScenarioSteps' rejects
-- any document Given that appears after the first When\/Then of its scenario
-- with 'StepGivenAfterDialog'.
data StepDef m c s a
    = GivenDef Pattern (c -> IO c)
      -- ^ accumulates the context; the action runs in 'IO' (lifted into @m@ by the interpreter) and has no access to the state
    | DialogDef GherkinKeyword Pattern (s -> m (s, Maybe a))
      -- ^ runs in @m@, threads the dialog state, and may emit a value ('Nothing' emits nothing); registered with 'WhenKeyword' or 'ThenKeyword' — 'GivenKeyword' is allowed but discouraged, it then behaves as a stateful Given
-- | Effective keyword a document step must carry to select this definition:
-- 'GivenKeyword' for 'GivenDef', the stored keyword for 'DialogDef'.
stepDefKeyword :: StepDef m c s a -> GherkinKeyword
stepDefKeyword GivenDef{} = GivenKeyword
stepDefKeyword (DialogDef kw _ _) = kw

-- | The pattern a document step text must match to select this definition.
stepDefPattern :: StepDef m c s a -> Pattern
stepDefPattern (GivenDef pat _) = pat
stepDefPattern (DialogDef _ pat _) = pat

-- | Builds a Given definition: matches document steps with resolved keyword
-- 'GivenKeyword' and accumulates the context.
givenDef :: Pattern -> (c -> IO c) -> StepDef m c s a
givenDef = GivenDef

-- | Builds a When definition: matches document steps with resolved keyword
-- 'WhenKeyword' and threads the dialog state.
whenDef :: Pattern -> (s -> m (s, Maybe a)) -> StepDef m c s a
whenDef = DialogDef WhenKeyword

-- | Builds a Then definition: matches document steps with resolved keyword
-- 'ThenKeyword' and threads the dialog state.
thenDef :: Pattern -> (s -> m (s, Maybe a)) -> StepDef m c s a
thenDef = DialogDef ThenKeyword

--------------------------------------------------------------------------------
-- Registry
--------------------------------------------------------------------------------

-- | An ordered collection of step definitions; the first entry whose keyword
-- and pattern match a document step wins.
newtype StepRegistry m c s a = StepRegistry
    { registryStepDefs :: [StepDef m c s a] -- ^ definitions in registration order
    }

-- | Combines two registries: the left one's definitions come first, so they
-- win under first-registered-match-wins.
instance Semigroup (StepRegistry m c s a) where
    StepRegistry xs <> StepRegistry ys = StepRegistry (xs <> ys)

-- | The empty registry: matches no step.
instance Monoid (StepRegistry m c s a) where
    mempty = emptyRegistry

-- | The registry without any definitions.
emptyRegistry :: StepRegistry m c s a
emptyRegistry = StepRegistry []

-- | Builds a registry from step definitions.
-- POST-CONTRACT: Matching tries the definitions in exactly the given order;
-- the first keyword-and-pattern match is executed.
mkRegistry :: [StepDef m c s a] -> StepRegistry m c s a
mkRegistry = StepRegistry

--------------------------------------------------------------------------------
-- Interpretation
--------------------------------------------------------------------------------

-- | Execution record of one executed document step, exposed so runners and
-- tests can inspect what ran, where, and with which captures.
data StepRun a = StepRun
    { stepRunKeyword :: GherkinKeyword          -- ^ resolved keyword of the executed step
    , stepRunText    :: Text                    -- ^ step text with the keyword stripped
    , stepRunLine    :: Int                     -- ^ 1-based source line of the step
    , stepRunParams  :: [(ParamName, ParamValue)] -- ^ parameters captured by the pattern
    , stepRunValue   :: Maybe a                 -- ^ value emitted by a Dialog step; 'Nothing' for Given steps and silent Dialog steps
    }
    deriving (Eq, Show)

-- | Everything collected from one interpreted scenario.
data StepOutcome c s a = StepOutcome
    { stepOutcomeContext :: c           -- ^ context after the last executed Given
    , stepOutcomeState   :: s           -- ^ dialog state after the last executed When\/Then
    , stepOutcomeValues  :: [a]         -- ^ values emitted by Dialog steps, in document order
    , stepOutcomeSteps   :: [StepRun a] -- ^ per-step records, in document order
    }
    deriving (Eq, Show)

-- | Interprets an already-expanded 'GherkinScenario' against a registry.
--
-- For each document step in order: the stored (already-resolved) keyword of
-- @And@\/@But@ steps participates directly in matching; the first registry
-- entry whose 'stepDefKeyword' equals the step keyword and whose
-- 'matchStep' succeeds on the step text is executed. 'GivenDef' entries
-- update the context (their 'IO' action is lifted into @m@); 'DialogDef'
-- entries thread the state and may emit a value. A Given appearing after the
-- first When\/Then of the scenario is a phase violation and aborts with
-- 'StepGivenAfterDialog'.
--
-- PRE-CONTRACT: None.
-- POST-CONTRACT: On 'Left', the first failing step in document order is
-- reported with its line, text and reason, and no further steps execute. On
-- 'Right', 'stepOutcomeValues' lists the emitted values in document order and
-- 'stepOutcomeSteps' mirrors the executed steps one to one.
runScenarioSteps
    :: MonadIO m
    => StepRegistry m c s a
    -> GherkinScenario -- ^ scenario with @And@\/@But@ already resolved (as produced by 'LazyCircus.Testing.Bdd.Gherkin.parseFeature')
    -> c               -- ^ initial context
    -> s               -- ^ initial dialog state
    -> m (Either StepError (StepOutcome c s a))
runScenarioSteps registry scenario c0 s0 =
    go (gherkinScenarioSteps scenario) c0 s0 False [] []
  where
    -- | Folds over the remaining steps, threading context, state, the
    -- dialog-phase flag, the emitted values and the step records (both in
    -- reverse order until the end).
    go remaining c s dialogStarted values runs = case remaining of
        [] ->
            pure
                (Right
                    StepOutcome
                        { stepOutcomeContext = c
                        , stepOutcomeState = s
                        , stepOutcomeValues = reverse values
                        , stepOutcomeSteps = reverse runs
                        })
        (step@GherkinStep{gherkinStepKeyword = kw, gherkinStepText = txt, gherkinStepLine = _} : rest)
            | dialogStarted && kw == GivenKeyword ->
                pure (Left (mkStepError step StepGivenAfterDialog))
            | otherwise -> case findMatch kw txt of
                Left reason -> pure (Left (mkStepError step reason))
                Right (entry, params) -> execute step rest entry params c s dialogStarted values runs

    -- | Executes one matched step and continues with the rest.
    execute step rest entry params c s dialogStarted values runs = case entry of
        GivenDef _ runGiven -> do
            c' <- liftIO (runGiven c)
            go rest c' s dialogStarted values (mkStepRun step params Nothing : runs)
        DialogDef _ _ runDialog -> do
            (s', result) <- runDialog s
            go
                rest
                c
                s'
                True
                (maybe values (: values) result)
                (mkStepRun step params result : runs)

    -- | Assembles the record of one executed step.
    mkStepRun :: GherkinStep -> [(ParamName, ParamValue)] -> Maybe a -> StepRun a
    mkStepRun GherkinStep{gherkinStepKeyword = kw, gherkinStepText = txt, gherkinStepLine = line} params value = StepRun
        { stepRunKeyword = kw
        , stepRunText = txt
        , stepRunLine = line
        , stepRunParams = params
        , stepRunValue = value
        }

    -- | Builds the structural error of one failing step.
    mkStepError :: GherkinStep -> StepErrorReason -> StepError
    mkStepError GherkinStep{gherkinStepText = txt, gherkinStepLine = line} reason = StepError
        { stepErrorScenario = gherkinScenarioName scenario
        , stepErrorLine = line
        , stepErrorStepText = txt
        , stepErrorReason = reason
        }

    -- | Finds the first registry entry whose effective keyword equals the
    -- step keyword and whose pattern matches the step text.
    -- POST-CONTRACT: On 'Left' 'StepKeywordMismatch', the carried keyword is
    -- that of the first entry (in registration order) whose pattern matches
    -- the text under a different keyword.
    findMatch kw text = case candidates of
        (entry, params) : _ -> Right (entry, params)
        []
            | (other : _) <- anyKeywordMatches -> Left (StepKeywordMismatch (stepDefKeyword other))
            | otherwise -> Left StepUndefinedStep
      where
        -- | Registry entries of the step's own keyword matching the text, in
        -- registration order.
        candidates =
            [ (entry, params)
            | entry <- registryStepDefs registry
            , stepDefKeyword entry == kw
            , Just params <- [matchStep (stepDefPattern entry) text]
            ]

        -- | Registry entries of any keyword matching the text, in
        -- registration order; used to distinguish a keyword mismatch from a
        -- completely undefined step.
        anyKeywordMatches =
            [ entry
            | entry <- registryStepDefs registry
            , isJust (matchStep (stepDefPattern entry) text)
            ]

--------------------------------------------------------------------------------
-- Structural errors
--------------------------------------------------------------------------------

-- | Why a document step could not be executed.
data StepErrorReason
    = StepUndefinedStep
      -- ^ no registry entry's pattern matches the step text under the step's resolved keyword
    | StepKeywordMismatch GherkinKeyword
      -- ^ the text matches a registry entry registered under the carried keyword instead
    | StepGivenAfterDialog
      -- ^ a Given step appeared after the first When\/Then step of its scenario
    deriving (Eq, Show)

-- | Structural description of one failing scenario step: which scenario, which
-- step (line and text), and why. Carries no file or feature name — those are
-- supplied by the runner at its own granularity.
data StepError = StepError
    { stepErrorScenario :: Text            -- ^ name of the scenario containing the failing step
    , stepErrorLine     :: Int             -- ^ 1-based source line of the failing step
    , stepErrorStepText :: Text           -- ^ step text with the keyword stripped
    , stepErrorReason   :: StepErrorReason -- ^ why the step could not be executed
    }
    deriving (Eq, Show)

-- | Renders a full 'StepError', including scenario, line and step text.
renderStepError :: StepError -> Text
renderStepError err =
    renderStepErrorReason (stepErrorReason err)
        <> " (scenario '"
        <> stepErrorScenario err
        <> "', line "
        <> tshow (stepErrorLine err)
        <> ", step '"
        <> stepErrorStepText err
        <> "')"

-- | Renders the expectation message of an error reason, without scenario,
-- line or step info; the caller appends those (e.g. via 'renderStepError').
renderStepErrorReason :: StepErrorReason -> Text
renderStepErrorReason reason = case reason of
    StepUndefinedStep -> "Expected a registered step definition matching the step's keyword and text, found none"
    StepKeywordMismatch kw -> "Expected a step definition with the step's own keyword, found the text only under a '" <> keywordName kw <> "' definition"
    StepGivenAfterDialog -> "Expected a When/Then step, found a Given after the first When/Then of the scenario"
  where
    -- | Canonical capitalization of a resolved keyword.
    keywordName kw = case kw of
        GivenKeyword -> "Given"
        WhenKeyword -> "When"
        ThenKeyword -> "Then"
