# Lazy Circus Reference: Scenarios

Read this when:

- writing or reviewing `ScenarioProgram`
- using `evalScript`, `throw`, `runSafely`, `getDateTime`, `withLogContext`, or `runAsync`
- reasoning about layer boundaries or overall architecture

## Contents

- Architecture Map
- Key Modules
- Writing Scenarios
- Using Log Context
- Using Extra Context And Feature Flags
- Using Async Work
- When To Use `runSafely`
- When To Use `runArbitraryIO`

## Architecture Map

```mermaid
flowchart TB
    subgraph Scene["Scene DSLs"]
        DB["DBScript db a"]
        TG["TelegramScript a"]
        AI["AIScript a"]
        MAIL["MailScript a"]
        HTTP["HTTPScript a"]
        LOG["LogLangF via HasLogLang"]
    end

    subgraph ScriptLayer["Script Coproduct"]
        SCRIPT["Script a<br/>TelegramScriptDef<br/>MailScriptDef<br/>AIScriptDef<br/>DBScriptDef<br/>HTTPScriptDef"]
    end

    subgraph ScenarioLayer["Scenario Layer"]
        SCEN["ScenarioProgram Script sl a<br/>evalScript / runSafely / getDateTime<br/>withLogContext / runAsync / callService"]
    end

    subgraph Runtime["Runtime Layer"]
        PERF["ScenarioPerformer Script sl m"]
        DEF["DefaultPerformer (DefaultApp sl)"]
        TEST["TestInterpreter sl"]
    end

    DB --> SCRIPT
    TG --> SCRIPT
    AI --> SCRIPT
    MAIL --> SCRIPT
    HTTP --> SCRIPT
    LOG -.->|embedded in| DB
    LOG -.->|embedded in| TG
    LOG -.->|embedded in| AI
    LOG -.->|embedded in| MAIL
    LOG -.->|embedded in| HTTP
    SCRIPT --> SCEN
    SCEN --> PERF
    PERF --> DEF
    PERF --> TEST
```

## Key Modules

- `LazyCircus.Scenario`: scenario DSL and orchestration combinators
- `LazyCircus.Script`: coproduct of supported sub-languages
- `LazyCircus.Performer`: generic `ScenarioPerformer Script` dispatch
- `LazyCircus.Performer.Default`: production interpreter stack
- `LazyCircus.Testing.Performer`, `LazyCircus.Testing.TgTest`, `LazyCircus.Testing.Updates`, and the `LazyCircus.Testing.Bdd.*` layer: shipped in the separate `lazy-circus-testing` subpackage (`testing/`), not in the core library (see [testing.md](testing.md) and [bdd.md](bdd.md))
- `LazyCircus.Scene.DB`, `LazyCircus.Scene.Telegram`, `LazyCircus.Scene.AI`, `LazyCircus.Scene.Mail`, `LazyCircus.Scene.HTTP`: stable public facades that re-export scene APIs and logging helpers
- `LazyCircus.Scene.*.Lang`: each effect language
- `LazyCircus.Scene.*.Class`: each effect performer interface and runner

Important implementation details:

- each language runner uses `iterM`
- `ScenarioProgram`, `DBScript`, `TelegramScript`, `AIScript`, `MailScript`, and `HTTPScript` are Church-encoded free monads
- logging is embedded into each language functor via `HasLogLang`

## Writing Scenarios

`ScenarioProgram script serviceLib a` is the orchestration layer. Use it for business workflows that combine
multiple effects and control concerns.

### Core Operations

| Function | Purpose |
|---|---|
| `evalScript` | run one embedded `Script` |
| `throw` | raise an exception through the interpreter |
| `runSafely` | catch typed exceptions and return `Either` |
| `degradeSafely` | best-effort run: on any exception emit one warning and yield a fallback value |
| `getDateTime` | get current UTC time |
| `log` / `logInfo` / `logWarn` / `logError` / `logSensitive` | scenario-level logging |
| `withLogContext` / `withLogEntry` / `with2LogEntries` | enrich logging context |
| `getExtraContext` / `readFromExtraContext` / `getFeatureFlag` | read runtime config |
| `readExtraContextKnob` | parse an extra-context knob with validation, degrading to a default |
| `runAsync` | schedule async work |
| `runAsyncAfter` | schedule deferred async work (one-shot timer: fires once, not before the delay, on an async worker; `delay <= 0` = immediate) |
| `runArbitraryIO` | **fallback** escape hatch — run an arbitrary `IO` when no structured effect fits (see below) |
| `callService` | call a registered service via the service library (blocks until the response) |
| `castService` | fire-and-forget call to a registered service (gen_server cast: returns immediately, handler errors invisible) |

Signatures (`sl` = `serviceLib`; module `LazyCircus.Scenario`):

```haskell
evalScript            :: script a -> ScenarioProgram script sl a
throw                 :: Exception e => e -> ScenarioProgram script sl a
runSafely             :: Exception e => ScenarioProgram script sl a -> ScenarioProgram script sl (Either e a)
degradeSafely         :: HasCallStack => Text -> a -> ScenarioProgram script sl a -> ScenarioProgram script sl a
getDateTime           :: ScenarioProgram script sl UTCTime
logInfo, logWarn, logError, logSensitive :: HasCallStack => Text -> ScenarioProgram script sl ()
withLogContext        :: [(Text, Text)] -> ScenarioProgram script sl a -> ScenarioProgram script sl a
withLogEntry          :: Show a => Text -> a -> ScenarioProgram script sl b -> ScenarioProgram script sl b
with2LogEntries       :: (Show a, Show b) => ((Text, a), (Text, b)) -> ScenarioProgram script sl z -> ScenarioProgram script sl z
getExtraContext       :: ScenarioProgram script sl (HashMap Text Text)
readFromExtraContext  :: Text -> ScenarioProgram script sl (Maybe Text)
getFeatureFlag        :: Text -> ScenarioProgram script sl Bool
readExtraContextKnob  :: (Read a, Show a) => Text -> (a -> Bool) -> a -> ScenarioProgram script sl a
runAsync              :: ScenarioProgram script sl () -> ScenarioProgram script sl ()
runAsyncAfter         :: NominalDiffTime -> ScenarioProgram script sl () -> ScenarioProgram script sl ()
runArbitraryIO        :: IO a -> ScenarioProgram script sl a
callService           :: IsInServiceLib sl req resp => req -> ScenarioProgram script sl resp
castService           :: (IsInServiceLib sl req resp, Typeable req) => req -> ScenarioProgram script sl ()

run                   :: ScenarioPerformer script sl m => ScenarioProgram script sl a -> m a
```

Top-level `Script` wrappers (module `LazyCircus`):

```haskell
tgScript   :: Text -> TelegramScript b -> Script b
dbScript   :: PgDB db -> DbMode -> DBScript db b -> Script b
aiScript   :: AIScript b -> Script b
mailScript :: MailScript b -> Script b
httpScript :: BaseUrl -> HTTPScript b -> Script b
```

### Rule Of Thumb

- use `logInfo` and friends in `ScenarioProgram`
- use `slogInfo` and friends inside scene languages
- use `evalScript` at the boundary between orchestration and domain effect code

### Minimal Scenario Example

```haskell
import Control.Monad (void)
import LazyCircus (Script, aiScript, tgScript)
import LazyCircus.App.Service (NoServiceLib)
import LazyCircus.Scene.AI (ask)
import LazyCircus.Scene.Telegram (sendMessage)
import LazyCircus.Scenario
import RIO

myScenario :: ScenarioProgram Script NoServiceLib ()
myScenario = do
    logInfo "Starting scenario"

    result <-
        ( runSafely $ do
            answer <- evalScript $ aiScript $ ask myRequest
            case answer of
                Nothing ->
                    throw $ userError "AI returned nothing"
                Just request ->
                    void $ evalScript $ tgScript "demo-bot" $ sendMessage request
        ) :: ScenarioProgram Script NoServiceLib (Either SomeException ())

    case result of
        Left err ->
            logError $ "Scenario failed: " <> tshow err
        Right () ->
            logInfo "Scenario completed"
```

Assume `myRequest :: AIRequest SendMessageRequest`.

### Using Log Context

For logging principles (what to log, where to place logs, what not to log), see
[reference/logging.md](logging.md).

```haskell
processAct :: Int32 -> ScenarioProgram Script serviceLib ()
processAct actId =
    withLogEntry "act_id" actId $ do
        logInfo "Starting act processing"
        withLogContext [("stage", "validation")] $ do
            logInfo "Validating act"
```

### Using Extra Context And Feature Flags

```haskell
featureScenario :: ScenarioProgram Script serviceLib ()
featureScenario = do
    env <- readFromExtraContext "env"
    enabled <- getFeatureFlag "some_flag"
    logInfo $ "env=" <> tshow env
    when enabled $
        logInfo "Feature is enabled"
```

For `Read`-able knobs (numbers, durations) use `readExtraContextKnob` instead of hand-rolling
`readMaybe`: it parses the raw value, validates it with a predicate, and degrades to a default —
silently when the key is absent, with exactly one `logWarn` when the value is garbage or fails
validation (garbage and invalid are not distinguished in the log).

```haskell
readExtraContextKnob :: (Read a, Show a) => Text -> (a -> Bool) -> a -> ScenarioProgram script sl a

-- Non-negative Int knob: "5" -> 5; key absent -> 10 with no log; "banana" or "-3" -> 10 with one warn.
maxRetries <- readExtraContextKnob "max-retries" (>= 0) 10
```

### Using Async Work

`runAsync` does not define how work is executed. It delegates to the active interpreter.

- in the default production runtime it is queued by `scheduleAsyncAction` into the shared action queue, then drained by the async worker loop — `runAsyncWorker` for a single worker, or `runAsyncWorkerPool n` for n competing workers over the same queue (n = 0 clamps to 1, n > 1024 to 1024, each with a warning; cancelling the caller thread stops all workers)
- in tests it is captured by default (`tcAsync = Mocked`) and not executed; with `tcAsync = Real` it is spawned on a background thread through the same test interpreter

```haskell
cleanupLater :: Int32 -> ScenarioProgram Script serviceLib ()
cleanupLater actId = do
    runAsync $ do
        logInfo "Background cleanup started"
        evalScript $ dbScript simpleDb ReadWrite $ delete (CircusActId actId)
        logInfo "Background cleanup finished"
```

`runAsyncAfter delay` defers work with a one-shot timer and delegates the same way:

- in production the action is registered via `scheduleTimedAction` in the `TimedActions` registry and served by `runTimerService`, which moves due programs into the shared queue drained by the async workers — the timer service thread must be running, otherwise deferred actions never fire
- in tests it is captured together with its delay in the `scheduledTimers` buffer when `tcAsync = Mocked` (`readScheduledTimers` to inspect, `fireScheduledTimers` to execute), and spawned once the delay elapses when `tcAsync = Real` — the same `tcAsync` knob controls both `runAsync` and `runAsyncAfter`

```haskell
cleanupMuchLater :: Int32 -> ScenarioProgram Script serviceLib ()
cleanupMuchLater actId =
    runAsyncAfter 3600 $ do
        logInfo "Delayed cleanup started"
        evalScript $ dbScript simpleDb ReadWrite $ delete (CircusActId actId)
```

`runAsyncAfter` is one-shot with no cancel handle. Periodic behavior is the re-arm pattern
at scenario level: a tick re-schedules itself while its condition holds, and cancellation
simply means stopping to re-arm:

```haskell
tick :: ScenarioProgram Script serviceLib ()
tick = do
    done <- isFinished
    unless done $ do
        doWork
        runAsyncAfter interval tick
```

### When To Use `runSafely`

Use `runSafely` only at boundaries where failure is expected and should be converted into data.

Good:

- wrapping an AI call that may fail
- isolating one optional notification branch
- converting DB or Telegram failure into a scenario decision

Avoid:

- wrapping the whole scenario by default
- swallowing errors without logging or handling them (when a logged fallback IS the intended handling, use `degradeSafely` instead of hand-rolled `runSafely` + discard)

### Graceful Degradation With `degradeSafely`

`degradeSafely` packages the most common `runSafely` use case — best effort, but never crash.
It runs the action with the exception type pinned to `SomeException`; on failure it emits
exactly one `logWarn` of the form `"<label>: <error>"` and yields a fallback value; on success
it yields the value and logs nothing.

```haskell
degradeSafely :: HasCallStack => Text -> a -> ScenarioProgram script sl a -> ScenarioProgram script sl a

-- Best-effort enrichment: on failure the count degrades to 0, with one warn in the logs.
unread <- degradeSafely "fetch-unread-count" 0 fetchUnreadCount
```

`label` is the caller's name of the degraded operation — make it specific enough to find the
failure in production logs. Use `degradeSafely` for optional, non-critical steps (nice-to-have
enrichment, cached counters, best-effort notifications) where a degraded answer is acceptable.
The warning log is the essential half of the contract: swallowing errors WITHOUT logging is
the anti-pattern — a `runSafely` whose `Left` is silently discarded hides the failure from
production observability and from test log captures alike. When the failure needs a real
decision or recovery beyond "log and fall back", use `runSafely` directly and handle the
`Either` yourself.

### When To Use `runArbitraryIO`

`runArbitraryIO` is an **escape hatch / last resort**. It lifts a raw `IO a` into the
scenario and is intended only for one-off side effects that fit nowhere else.

Reach for it ONLY after ruling out:

- a scene language (`DB`, `Telegram`, `AI`, `Mail`, `HTTP`)
- a registered service (`callService` / `castService`)
- a new scene language / service if the operation is worth keeping

Caveats:

- the `IO` runs for real in BOTH the production and the test interpreter — it
  cannot be mocked, captured, or asserted on the way Telegram/AI/Mail sends can
- it is invisible to `timedAndLog` automatic timing and to structured
  observability
- anything non-trivial run through it becomes a testing and maintenance burden

```haskell
-- Discouraged but available:
result <- runArbitraryIO someOneOffIO
```

If you find yourself using `runArbitraryIO` repeatedly for the same kind of
operation, that is a signal to promote it to a proper scene language or service.