{- |
Step definitions and a generic interpreter for already-expanded
'GherkinScenario's — the third layer of the BDD runner. 'parseFeature'
('LazyCircus.Testing.Bdd.Gherkin') produces scenarios, 'matchStep'
('LazyCircus.Testing.Bdd.Pattern') binds step texts to patterns, and this
module wires both together: a 'StepRegistry' collects 'StepDef's, and
'runScenarioSteps' executes a scenario's steps against it, threading the
captured parameters and a context @c@ through Given steps and a dialog state
@s@ through When\/Then steps.

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
      -- * Selection
    , matchingDefs
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
    = GivenDef Pattern (StepParams -> c -> IO c)
      -- ^ accumulates the context, receiving the captured parameters; the action runs in 'IO' (lifted into @m@ by the interpreter) and has no access to the state
    | DialogDef GherkinKeyword Pattern (StepParams -> s -> m (s, Maybe a))
      -- ^ receives the captured parameters, runs in @m@, threads the dialog state, and may emit a value ('Nothing' emits nothing); registered with 'WhenKeyword' or 'ThenKeyword' — 'GivenKeyword' is allowed but discouraged, it then behaves as a stateful Given

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
-- 'GivenKeyword' and accumulates the context, passing the captured
-- parameters to the action.
givenDef :: Pattern -> (StepParams -> c -> IO c) -> StepDef m c s a
givenDef = GivenDef

-- | Builds a When definition: matches document steps with resolved keyword
-- 'WhenKeyword' and threads the dialog state, passing the captured
-- parameters to the action.
whenDef :: Pattern -> (StepParams -> s -> m (s, Maybe a)) -> StepDef m c s a
whenDef = DialogDef WhenKeyword

-- | Builds a Then definition: matches document steps with resolved keyword
-- 'ThenKeyword' and threads the dialog state, passing the captured
-- parameters to the action.
thenDef :: Pattern -> (StepParams -> s -> m (s, Maybe a)) -> StepDef m c s a
thenDef = DialogDef ThenKeyword

--------------------------------------------------------------------------------
-- Registry
--------------------------------------------------------------------------------

-- | An ordered collection of step definitions; matching entries are selected
-- by 'matchingDefs' — 'Literal' patterns before 'Template' patterns,
-- registration order within each class.
newtype StepRegistry m c s a = StepRegistry
    { registryStepDefs :: [StepDef m c s a] -- ^ definitions in registration order
    }

-- | Combines two registries: the left one's definitions come first, keeping
-- registration order within each of 'matchingDefs'' priority classes
-- ('Literal' matches before 'Template' matches).
instance Semigroup (StepRegistry m c s a) where
    StepRegistry xs <> StepRegistry ys = StepRegistry (xs <> ys)

-- | The empty registry: matches no step.
instance Monoid (StepRegistry m c s a) where
    mempty = emptyRegistry

-- | The registry without any definitions.
emptyRegistry :: StepRegistry m c s a
emptyRegistry = StepRegistry []

-- | Builds a registry from step definitions.
-- POST-CONTRACT: Selection follows 'matchingDefs': 'Literal' matches first,
-- then 'Template' matches, each class in exactly the given order; the head of
-- 'matchingDefs' is the definition a run executes.
mkRegistry :: [StepDef m c s a] -> StepRegistry m c s a
mkRegistry = StepRegistry

--------------------------------------------------------------------------------
-- Selection
--------------------------------------------------------------------------------

-- | All registry definitions matching a document step, paired with the
-- parameters their patterns capture.
--
-- PRE-CONTRACT: None.
-- POST-CONTRACT: The result is ordered — 'Literal' matches first (in
-- registration order among themselves), then 'Template' matches (in
-- registration order) — and 'runScenarioSteps' executes the head, so a
-- 'Literal' match deterministically shadows any number of competing
-- 'Template' matches.
matchingDefs
    :: StepRegistry m c s a
    -> GherkinKeyword -- ^ resolved keyword of the document step
    -> Text -- ^ step text with the keyword stripped
    -> [(StepDef m c s a, StepParams)]
matchingDefs registry kw text = literalMatches <> templateMatches
  where
    -- | All same-keyword definitions whose pattern matches the text, in
    -- registration order.
    matches =
        [ (entry, params)
        | entry <- registryStepDefs registry
        , stepDefKeyword entry == kw
        , Just params <- [matchStep (stepDefPattern entry) text]
        ]
    -- | Exact definitions win over templates: a fully spelled-out step text
    -- is the more specific, intended selection.
    literalMatches = filter (isLiteralPattern . stepDefPattern . fst) matches
    templateMatches = filter (not . isLiteralPattern . stepDefPattern . fst) matches

-- | Whether a pattern is a 'Literal' (exact) rather than a 'Template'.
isLiteralPattern :: Pattern -> Bool
isLiteralPattern (Literal _) = True
isLiteralPattern Template{} = False

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
-- @And@\/@But@ steps participates directly in matching; the head of
-- 'matchingDefs' — 'Literal' matches before 'Template' matches, each class in
-- registration order — is executed. 'GivenDef' entries
-- update the context (their 'IO' action is lifted into @m@); 'DialogDef'
-- entries thread the state and may emit a value. Both receive the parameters
-- captured by the matched pattern. A Given appearing after the
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
    -- POST-CONTRACT: A pattern binding a parameter name more than once fails
    -- the step with 'StepDuplicateParam' (carrying the first duplicated name
    -- in pattern order) before the action runs.
    execute step rest entry params c s dialogStarted values runs
        | (dup : _) <- duplicateParamNames (stepDefPattern entry) =
            pure (Left (mkStepError step (StepDuplicateParam dup)))
        | otherwise = case entry of
            GivenDef _ runGiven -> do
                c' <- liftIO (runGiven params c)
                go rest c' s dialogStarted values (mkStepRun step params Nothing : runs)
            DialogDef _ _ runDialog -> do
                (s', result) <- runDialog params s
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

    -- | Selects the definition for one step: the head of 'matchingDefs'.
    -- POST-CONTRACT: On 'Left' 'StepKeywordMismatch', the carried keyword is
    -- that of the first entry (in registration order) whose pattern matches
    -- the text under a different keyword.
    findMatch kw text = case matchingDefs registry kw text of
        (entry, params) : _ -> Right (entry, params)
        []
            | (other : _) <- anyKeywordMatches -> Left (StepKeywordMismatch (stepDefKeyword other))
            | otherwise -> Left StepUndefinedStep
      where
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
    | StepDuplicateParam ParamName
      -- ^ the matched pattern binds the carried parameter name more than once
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
    StepDuplicateParam name -> "Expected the matched step definition to capture each parameter at most once, found " <> tshow name <> " captured more than once"
    StepGivenAfterDialog -> "Expected a When/Then step, found a Given after the first When/Then of the scenario"
  where
    -- | Canonical capitalization of a resolved keyword.
    keywordName kw = case kw of
        GivenKeyword -> "Given"
        WhenKeyword -> "When"
        ThenKeyword -> "Then"
