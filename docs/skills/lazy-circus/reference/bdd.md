# Lazy Circus Reference: BDD Feature Specs (`lazy-circus-testing`)

Read this when:

- writing or reviewing Gherkin `.feature` specs executed as hspec scenarios
- registering step definitions (`givenDef` / `whenDef` / `thenDef`) in a registry
- observing side effects through the journal (`tcJournal`, `awaitObservation`)
- wiring `gherkinSpec` for an application

Everything here lives in the `lazy-circus-testing` subpackage (`testing/`), NOT in the
core library — consumers add it as a second package pinned from the same git commit
(see "Using the `lazy-circus-testing` subpackage" in the repository README). hspec is a
library dependency of this subpackage only; the core stays hspec-free.

## Contents

- Module Map
- The Pipeline
- Feature File Subset
- Step Definitions And The Registry
- Journal: Observations And Cursor Waits
- The Runner (`gherkinSpec`)
- Given Combinators
- Worked Example (Echo Bot)
- Review Checklist

## Module Map

| Module | Responsibility |
|---|---|
| `LazyCircus.Testing.Bdd.Gherkin` | pure `parseFeature :: Text -> Either GherkinParseError GherkinFeature`; AST carries line numbers; Outline rows expand at parse time |
| `LazyCircus.Testing.Bdd.Pattern` | the `Pattern` ADT (`Template` / `Literal`, `IsString`), `matchStep :: Pattern -> Text -> Maybe [(ParamName, ParamValue)]`; quoted spans `"..."` and `«...»` capture strictly quoted values; `patternSource`, `duplicateParamNames`, `matchAll` (every matching name, input order) |
| `LazyCircus.Testing.Bdd.Step` | `StepDef m c s a` (actions receive the captured `StepParams`), `StepRegistry` with deterministic `matchingDefs` selection (`Literal` first, then `Template` in registration order), `runScenarioSteps`, structural `StepError` values |
| `LazyCircus.Testing.Bdd.Journal` | `Observation app`, append-only `ObservationLog`, `awaitObservation`, `peekLastConsumed`, `ScenarioState` |
| `LazyCircus.Testing.Bdd.Tg` | ready-made Telegram `Then` dictionary over the journal (expected values read from captures via `lookupParam`) and the canonical `tgTestBootstrap` |
| `LazyCircus.Testing.Bdd.Given` | `AppContext app` and Given-phase staging combinators |
| `LazyCircus.Testing.Bdd.Runner` | `gherkinSpec`: hspec tree, coverage meta-test, ambiguity probe, `@blocked` |

## The Pipeline

1. **Parse + meta-test, before any scenario runs.** `gherkinSpec` parses the feature and
   emits one hspec example requiring EVERY step of EVERY scenario to match a registry entry
   by resolved keyword and pattern. Failures are collected into a single red listing
   `feature / scenario / line / step text`. An unmatched step is a spec-build error, never a
   hanging run.
2. **Given** actions materialize context (`AppContext app`): staged downloads, queued AI
   answers, app seeds. The default context is empty — a spec must declare what it uses.
3. **When/Then** dialog steps execute in document order inside `TelegramTestScript`.
   Effects go to the test performer, which appends an `Observation` to the journal in the
   SAME STM transaction that publishes to the outgoing mailbox (order between the two
   channels is stable by construction).
4. **Then** consumes journal entries via `awaitObservation`: scan past consumed entries,
   first match wins, explicit `AwaitTimeout` on budget expiry. Observations skipped by a
   selective wait stay available to later waits (consumed-set semantics, not a cursor).
5. **And-continuations** read the last consumed observation via `peekLastConsumed` — they
   never wait and never consume.
6. **After the scenario** the runner hands the full journal snapshot to the verifier for
   negative checks ("nothing else was sent").

## Feature File Subset

Supported: `Feature:` with description lines, tags above features and scenarios (carried
in the AST; the runner acts on `@blocked`), `Scenario:`, `Scenario Outline:` + `Examples:`
(placeholders `<param>` substitute into steps AND the scenario name; each row becomes its
own scenario), `And`/`But` (stored in the AST with the RESOLVED keyword), wrapped steps (a
plain non-keyword line inside a scenario continues the previous step's text — the two
trimmed texts join with a single space, and the step keeps the line of its first line),
`#` comments, empty lines.
Errors carry 1-based line numbers (step outside a scenario, `Examples` without a header
row, `And`/`But` before any `Given`/`When`/`Then`).

Not supported: docstrings (`"""`) and data tables in steps.

Patterns are the `Pattern` ADT: a string literal denotes a `Template`, and a `Literal`
matches exactly (quotes are ordinary characters there — use it for step texts that
contain quotes verbatim). In a template, quoted spans `"name"` and `«name»` hold the
parameter NAME; the captured step text is the VALUE. Matching is STRICT about quote
boundaries: a value must appear in the step text wrapped in a PAIR of matching quote
characters — either style, regardless of the style the span uses (`"alice"`, `«alice»`,
or a guillemet value under a straight-quote span all match the span `"name"`), the
capture is the non-empty text strictly between the quotes, and the first closer ends it.
Unquoted pattern text must match literally; both sides are whitespace-normalized first
(runs of spaces/tabs collapse to one space, ends trimmed), but quote characters survive
normalization — collapsing never merges text across a quoted span. An unterminated
quoted span in the pattern is not an error: it and the rest of the pattern match
literally.

## Step Definitions And The Registry

```haskell
data StepDef m c s a
    = GivenDef Pattern (StepParams -> c -> IO c)                           -- pure accumulation, captures delivered
    | DialogDef GherkinKeyword Pattern (StepParams -> s -> m (s, Maybe a)) -- keyword participates in matching
```

- All `Given` steps of a scenario must precede its first `When`/`Then` — violations are
  structural `StepError` values with the line number, not runtime exceptions.
- Matching uses the step's RESOLVED keyword: a `Then` step never fires a When-registered
  pattern.
- Registries are `Semigroup`/`Monoid`; `mkRegistry` builds one. Selection is
  deterministic via `matchingDefs`: `Literal` patterns match FIRST, then `Template`
  patterns, each class in registration order — a fully spelled-out step text always wins
  over competing templates, so no registration-order discipline is required.
- Captured parameters are delivered to the action as `StepParams` (name/value pairs in
  the order the quoted spans appear in the pattern); read one with
  `lookupParam :: ParamName -> StepParams -> Maybe ParamValue` — `Nothing` only for a
  name the pattern does not contain. A pattern binding the same name twice fails the
  step at execution with `StepDuplicateParam`, before the action runs.
- The interpreter is generic over `m` (needs `MonadIO` only); the canonical instantiation
  is `m = TelegramTestScript`, `c = AppContext app`, `s = ScenarioState app` — that is,
  `ScenarioRegistry serviceLib app m = StepRegistry m (AppContext app) (ScenarioState app) ()`.

```haskell
registry :: ScenarioRegistry NoServiceLib () TelegramTestScript
registry = mkRegistry
    [ givenDef "the echo bot is awake" (\_params -> pure . id)
    , whenDef "the user sends \"$msg\"" $ \params st -> do
        _ <- sendMessage (fromMaybe "" (lookupParam "$msg" params))  -- plain TelegramTestScript effect
        pure (st, Nothing)
    , botReplyContains                      -- library Then-dictionary values: the expected
    , botRepliesWithMessage                 -- texts are read from their own captures
    ]
```

## Journal: Observations And Cursor Waits

```haskell
data Observation app
    = ObsTgMessage  { obsChatId :: Maybe ChatId, obsText :: Text
                    , obsMsgId :: MessageId, obsMarkup :: Maybe SomeReplyMarkup }
    | ObsTgDocument { obsChatId :: Maybe ChatId, obsFileId :: Maybe FileId }
    | ObsTgPoll     { obsChatId :: Maybe ChatId, obsQuestion :: Text }
    | ObsTgInvoice  { obsChatId :: Maybe ChatId, obsTitle :: Text }
    | ObsTgReaction { obsTargetMsgId :: Maybe MessageId }
    | ObsTgEdit     { obsTargetMsgId :: Maybe MessageId, obsNewText :: Text }
    | ObsTgDelete   { obsTargetMsgId :: Maybe MessageId }
    | ObsTgPreCheckoutAnswer { obsQueryId :: Text, obsOk :: Bool }
    | ObsAsyncScheduled { obsScenarioDesc :: Text }   -- runAsync capture
    | ObsTimerScheduled { obsScenarioDesc :: Text }   -- timer-service capture
    | ObsApp app                    -- your facts, via tcMailHook / tcAiHook / direct append

newObservationLog  :: IO (ObservationLog app)
appendObservation  :: ObservationLog app -> Observation app -> STM ()
readObservations   :: ObservationLog app -> IO [Observation app]   -- commit-order snapshot

awaitObservation   :: Int -> ScenarioState app -> (Observation app -> Bool) -> Text
                   -> IO (Either AwaitTimeout (Observation app, ScenarioState app))
peekLastConsumed   :: ScenarioState app -> IO (Maybe (Sequenced (Observation app)))
defaultAwaitBudgetUs :: Int   -- 2s, mirroring TgTest's default
```

Conventions (all enforced by Haddock contracts and tests):

- one `awaitObservation` on `ObsTgMessage` consumes exactly ONE message; two identical
  messages require two awaits
- consumption is recorded in the returned `ScenarioState` (`ssConsumed :: Set Int`); the
  journal itself is never mutated by waits
- unconsumed observations stay matchable for later waits even when an earlier selective
  wait scanned past them
- the journal and the outgoing mailbox are written in one `atomically` per Telegram effect,
  so mailbox order and journal order always agree
- non-Telegram effects reach the journal as `ObsApp` through the hooks (`tcMailHook`,
  `tcAiHook`) — or via direct `appendObservation` from any layer that holds the log
- scheduled async scenarios and timers are journaled by the test performer as
  `ObsAsyncScheduled` / `ObsTimerScheduled`, described by `obsScenarioDesc`
- the blessing rule: a new library `Observation` constructor is added only after an
  observation shape has survived at least two scenarios through app hooks

## The Runner (`gherkinSpec`)

```haskell
gherkinSpec :: MonadIO m
    => FeatureSource                                          -- FeatureFile path | FeatureInline
    -> (GherkinScenario -> IO (ScenarioRegistry serviceLib app m))  -- registry per scenario
    -> ScenarioBootstrap serviceLib app m                     -- builds the executor from the runner-allocated fresh journal + mocks
    -> ScenarioVerifier app                                   -- post-scenario: outcome + journal snapshot
    -> Spec
```

- the tree is `describe <feature label>` → one `it` per scenario (each Outline row is its
  own `it` with the substituted name), preceded by the meta-test and the ambiguity probe
- `@blocked` scenarios become `pendingWith` skips (their steps still must be registered)
- the ambiguity probe is a visible, NON-blocking example listing same-phase registry
  templates that both match a probe text (a `Literal` match shadows templates by rule
  and is never reported as ambiguous)
- isolation mirrors `tgTest`: a fresh `ObservationLog` and fresh `Mocks` per scenario
- the CANONICAL bootstrap is `tgTestBootstrap` (`LazyCircus.Testing.Bdd.Tg`): pass it
  your run config and `buildAction` — `tgTestBootstrap defaultTgTestConfig (buildAction
  app)` — and the library wires each scenario's fresh journal via `tcJournal` and runs
  the step program as a `tgTestWithMocks` dialog over the runner-owned mocks (a
  `gherkinSpec` scenario IS a `tgTest` run)
- the runner never touches PostgreSQL; `testing/test/Bdd/RunnerSpec.hs` shows a
  database-free `DefaultApp` construction for the test-performer path
- known limitation: attribution of a failed step is runner-granular (the `StepError`
  surfaces after the pilot run); pinpoint the step via `renderStepError`

## Given Combinators

```haskell
data AppContext app = AppContext               -- wiring for mock targets + the seed accumulator
emptyAppContext :: AppContext app              -- the DEFAULT: nothing wired
appContextFor   :: Mocks serviceLib -> AppContext app   -- wire mock targets

-- Given-action producers: each returns `AppContext app -> IO (AppContext app)` —
-- exactly the action slot of `GivenDef` once the captured params are fixed
-- (`\_params -> stagedTgDownloads ...`); fixture values are NOT baked in at
-- registration — a staging step keys them off its own captures:
stagedTgDownloads :: [(FileId, ByteString)]
                  -> AppContext app -> IO (AppContext app)  -- stage canned downloads (addTgDownloads)
queuedAiAnswers   :: [Chat.ChatCompletionObject]
                  -> AppContext app -> IO (AppContext app)  -- FIFO AI mock answers
withAppSeed       :: app
                  -> AppContext app -> IO (AppContext app)  -- accumulate an app-specific seed

-- > givenDef "file \"$name\" is downloadable" $ \params ->
-- >     stagedTgDownloads [(FileId (fromMaybe "doc-1" (lookupParam "$name" params)), pdfBytes)]
```

The default context is empty by design: a spec cannot silently rely on fixtures it never
declared — staging into an unwired context fails loudly.

## Worked Example (Echo Bot)

`testing/test/Bdd/EchoSmokeSpec.hs` runs an inline feature through `gherkinSpec` against a
database-free echo app. The registry is a STATIC value shared by every scenario
(`\_ -> pure echoRegistry`) — nothing is baked in at registration: the When action reads
the user's words via `lookupParam "$msg"`, the Given staging def keys the canned bytes
off its own `"$name"` capture, and the library Then-constructors read their expected
texts from their own captures. The bootstrap is the canonical `tgTestBootstrap
defaultTgTestConfig (buildEchoAction app)`.

Covered flows: When `the user sends "$msg"` drives `sendMessage`; Then `the bot replies
with "$text"` consumes the journaled reply; And `the bot replies with a message
containing "$frag"` re-inspects the last consumed message without waiting; the scenario
`echoes twice with different words` runs the same When/Then patterns at two values (the
static-registry regression); the scenario `replies with the staged file size` stages a
download via `file "doc-1" is downloadable`, uploads it via `the user uploads document
"$file"`, and asserts the byte-length reply. The suite passes with PostgreSQL stopped —
DB and HTTP are the only always-real sub-languages and the echo never touches them.

## Review Checklist

- Does every feature step match a registry entry (meta-test green) and does the ambiguity
  probe report no unintended collisions?
- Does every pattern bind each parameter name at most once (`StepDuplicateParam` fails
  the step at execution)?
- Do feature steps quote every parameter value (`"value"` / `«value»`)? An unquoted
  value does not match.
- Is deterministic selection used consciously (`Literal` beats competing templates;
  within a class, registration order decides)?
- Are `Given` steps before the first `When`/`Then`, and is the default context empty unless
  fixtures are explicitly staged?
- Is each `Then` consuming exactly one observation, with `And`-continuations reading via
  `peekLastConsumed` (never waiting, never consuming)?
- Are app-specific facts journaled as `ObsApp` (hooks or direct append) instead of
  overloading Telegram constructors?
- Is a new blessed `Observation` constructor justified by two surviving scenarios?
- Was `hpack` AND `hpack testing` run before building?
