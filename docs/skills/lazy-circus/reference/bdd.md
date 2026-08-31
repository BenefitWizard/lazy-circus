# Lazy Circus Reference: BDD Feature Specs (`lazy-circus-testing`)

Read this when:

- writing or reviewing Gherkin `.feature` specs executed as hspec scenarios
- registering step definitions (`givenDef` / `whenDef` / `thenDef`) in a registry
- observing side effects through the journal (`tcJournal`, `awaitObservation`)
- wiring `gherkinSpec` for an application

Everything here lives in the `lazy-circus-testing` subpackage (`testing/`), NOT in the
core library — consumers add it as a second package pinned from the same git commit
(see "Pin both packages" in the repository README). hspec is a library dependency of
this subpackage only; the core stays hspec-free.

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
| `LazyCircus.Testing.Bdd.Pattern` | `matchStep :: Pattern -> Text -> Maybe [(ParamName, ParamValue)]`; quoted spans `"..."` and `«...»` capture parameters; `matchAll` for the ambiguity probe |
| `LazyCircus.Testing.Bdd.Step` | `StepDef m c s a`, `StepRegistry` (first registered match wins), `runScenarioSteps`, structural `StepError` values |
| `LazyCircus.Testing.Bdd.Journal` | `Observation app`, append-only `ObservationLog`, `awaitObservation`, `peekLastConsumed`, `ScenarioState` |
| `LazyCircus.Testing.Bdd.Tg` | ready-made Telegram `Then` dictionary over the journal |
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

Supported: `Feature:` with description lines, tags (`@blocked`, `@focus`) above features
and scenarios, `Scenario:`, `Scenario Outline:` + `Examples:` (placeholders `<param>`
substitute into steps AND the scenario name; each row becomes its own scenario),
`And`/`But` (stored in the AST with the RESOLVED keyword), `#` comments, empty lines.
Errors carry 1-based line numbers (step outside a scenario, `Examples` without a header
row, `And`/`But` before any `Given`/`When`/`Then`).

Not supported: docstrings (`"""`) and data tables in steps.

Parameters live in the PATTERN side as quoted spans — `"name"` and `«name»`. The span
content is the parameter NAME; the captured step text is the VALUE. Unquoted pattern text
must match literally after whitespace normalization (runs of whitespace collapse to one
space on both sides). Captures are non-empty and resolve shortest-first.

## Step Definitions And The Registry

```haskell
data StepDef m c s a
    = GivenDef Pattern (c -> IO c)                          -- pure accumulation
    | DialogDef GherkinKeyword Pattern (s -> m (s, Maybe a)) -- keyword participates in matching
```

- All `Given` steps of a scenario must precede its first `When`/`Then` — violations are
  structural `StepError` values with the line number, not runtime exceptions.
- Matching uses the step's RESOLVED keyword: a `Then` step never fires a When-registered
  pattern.
- Registries are `Semigroup`/`Monoid`; `mkRegistry` builds one; the FIRST registered
  matching definition wins. Register narrower patterns before catch-alls.
- The interpreter is generic over `m` (needs `MonadIO` only); the canonical instantiation
  is `StepM app = TelegramTestScript`, `c = AppContext app`, `s = ScenarioState app`.

```haskell
registry :: ScenarioRegistry NoServiceLib () TelegramTestScript
registry = mkRegistry
    [ givenDef "the echo bot is awake" (pure . id)
    , whenDef "пользователь отправляет \"$msg\"" $ \st -> do
        _ <- sendMessage msg                -- plain TelegramTestScript effect
        pure (st, Nothing)
    , botReplyContains frag                 -- BEFORE the catch-all exact-match step
    , botRepliesWithMessage msg
    ]
```

## Journal: Observations And Cursor Waits

```haskell
data Observation app
    = ObsTgMessage  { obsChatId :: Maybe ChatId, obsText :: Text
                    , obsMsgId :: MessageId, obsMarkup :: Maybe SomeReplyMarkup }
    | ObsTgDocument { obsChatId :: Maybe ChatId, obsFileId :: Maybe FileId }
    | ObsTgReaction { obsTargetMsgId :: Maybe MessageId }
    | ObsTgEdit     { obsTargetMsgId :: Maybe MessageId, obsNewText :: Text }
    | ObsTgDelete   { obsTargetMsgId :: Maybe MessageId }
    | ObsAsyncScheduled { obsScenarioDesc :: Text }
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
- the blessing rule: a new library `Observation` constructor is added only after an
  observation shape has survived at least two scenarios through app hooks

## The Runner (`gherkinSpec`)

```haskell
gherkinSpec :: MonadIO m
    => FeatureSource                                          -- FeatureFile path | FeatureInline
    -> (GherkinScenario -> IO (ScenarioRegistry serviceLib app m))  -- registry per scenario
    -> ScenarioBootstrap serviceLib app m                     -- app bootstrap (owns journal + mocks freshness)
    -> ScenarioVerifier app                                   -- post-scenario: outcome + journal snapshot
    -> Spec
```

- the tree is `describe <feature label>` → one `it` per scenario (each Outline row is its
  own `it` with the substituted name), preceded by the meta-test and the ambiguity probe
- `@blocked` scenarios become `pendingWith` skips (their steps still must be registered)
- the ambiguity probe is a visible, NON-blocking example listing same-phase registry
  patterns that both match a probe text
- isolation mirrors `tgTest`: a fresh `ObservationLog` and fresh `Mocks` per scenario
- the runner never touches PostgreSQL; `testing/test/Bdd/RunnerSpec.hs` shows a
  database-free `DefaultApp` construction for the test-performer path
- known limitation: attribution of a failed step is runner-granular (the `StepError`
  surfaces after the pilot run); pinpoint the step via `renderStepError`

## Given Combinators

```haskell
data AppContext app = AppContext               -- wiring for mock targets + the seed accumulator
emptyAppContext :: AppContext app              -- the DEFAULT: nothing wired
appContextFor   :: Mocks serviceLib -> AppContext app   -- wire mock targets

stagedTgDownloads :: ... -> GivenDef ...   -- stage canned downloads (addTgDownloads)
queuedAiAnswers   :: ... -> GivenDef ...   -- FIFO AI mock answers
withAppSeed       :: ... -> GivenDef ...   -- accumulate an app-specific seed
```

The default context is empty by design: a spec cannot silently rely on fixtures it never
declared — staging into an unwired context fails loudly.

## Worked Example (Echo Bot)

`testing/test/Bdd/EchoSmokeSpec.hs` runs an inline feature through `gherkinSpec` against a
database-free echo app: When «пользователь отправляет "$msg"» drives `sendMessage`, Then
«бот отвечает сообщением "$msg"» consumes the journaled reply, And «...содержит "$frag"»
re-inspects the last consumed message without waiting. The suite passes with PostgreSQL
stopped — DB and HTTP are the only always-real sub-languages and the echo never touches them.

## Review Checklist

- Does every feature step match a registry entry (meta-test green) and does the ambiguity
  probe report no unintended collisions?
- Are narrower patterns registered before catch-alls (first match wins)?
- Are `Given` steps before the first `When`/`Then`, and is the default context empty unless
  fixtures are explicitly staged?
- Is each `Then` consuming exactly one observation, with `And`-continuations reading via
  `peekLastConsumed` (never waiting, never consuming)?
- Are app-specific facts journaled as `ObsApp` (hooks or direct append) instead of
  overloading Telegram constructors?
- Is a new blessed `Observation` constructor justified by two surviving scenarios?
- Was `hpack` AND `hpack testing` run before building?
