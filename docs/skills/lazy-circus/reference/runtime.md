# Lazy Circus Reference: Production Runtime

Read this when:

- working with `DefaultPerformer`, `DefaultApp`, or `evalScriptDefault`
- reasoning about connection pools, environment projection, or dispatch paths
- sizing or tearing down the async worker pool

Modules: `LazyCircus.Performer.Default`, `LazyCircus.AsyncWorker` / `LazyCircus.AsyncWorker.Types`,
`LazyCircus.DB.WithConnection`, `LazyCircus.Telegram.Types`. For the test runtime, see
[testing.md](testing.md).

## Contents

- Main Production Runtime
- Wrapper Environments
- `changeEnv`
- Dispatch Paths
- Async Worker Pool
- Timer Service
- Review Checklist

## Main Production Runtime

`LazyCircus.Performer.Default` defines:

```haskell
newtype DefaultPerformer env a = DefaultPerformer
    { runDefaultPerformer :: RIO env a }
```

`runDefaultScenario :: ScenarioProgram Script serviceLib a -> DefaultPerformer (DefaultApp serviceLib) a`

Note: `runDefaultScenario` is not currently exported. Production scenarios are run via the generic `run` function:
`runRIO app $ runDefaultPerformer $ run @Script @serviceLib myScenario`

`DefaultApp serviceLib` contains:

- primary PostgreSQL connection pool (`pgDbPool`; total connection cap set by `cfgPgPoolMaxResources` in `DefaultAppConfig`; every DB script checks out one connection for its whole duration)
- optional read-only PostgreSQL connection pool (`pgDbPoolReadOnly`; `ReadOnly` scripts fall back to the primary pool when it is unset)
- Telegram bot environments
- OpenAI client methods
- SMTP credentials
- shared logging queue and logging context
- extra context map
- scheduled async action queue
- JWT settings, process context, and a SQL log hook
- service library (or `NoServiceLib`)
- tool descriptions available to AI interpreters
- tool call executor for dispatching named tool calls with JSON arguments
- shared TLS connection manager for HTTP client requests

`newDefaultApp` probes each configured pool at construction (an unreachable database
fails startup) and validates `cfgPgPoolMaxResources >= 1`. The caller must release the
pools via `destroyAllResources` after cancelling worker threads.

## Wrapper Environments

### `AppWithConnection`

Module: `LazyCircus.DB.WithConnection`

Use this when one interpreter must run against a selected DB connection while preserving access
to the rest of the application environment.

The default performer checks out one connection per DB script from the app's pool — the
read-only pool when configured (falling back to the read-write pool) — and projects into
`AppWithConnection` for the duration of the script.

### `AppWithBotEnv`

Module: `LazyCircus.Telegram.Types`

Use this when a Telegram script needs one specific bot environment.

The default performer looks up the bot by name and projects into `AppWithBotEnv` before running
`runTelegram`.

## `changeEnv`

`changeEnv` projects one performer into another environment.

```haskell
changeEnv :: (outer -> inner) -> DefaultPerformer inner a -> DefaultPerformer outer a
```

This is not a lens update. It is a pure projection from outer environment to inner environment.

## Dispatch Paths

There are two important execution entry points:

1. `run` from `LazyCircus.Scenario` together with the `ScenarioPerformer`
   instance for `DefaultPerformer` (defined in `LazyCircus.Performer.Default`;
   `LazyCircus.Performer` re-exports that module)
2. `evalScriptDefault` from `LazyCircus.Performer.Default` — the production dispatch that
   pattern-matches on `Script` variants

The production `ScenarioPerformer` instance:

- dispatches `Script` through `evalScriptDefault` (which calls `runTelegram`, `runMail`,
  `runAI`, `runDB`, and `runHTTP`)
- queues async work via `scheduleAsyncAction`
- reads the real `extraContext` map from `DefaultApp`

The default performer's `evalScriptDefault` is the production-specific dispatch. It:

- looks up the requested Telegram bot name and throws `NoBotConfigured` when absent
- projects into `AppWithBotEnv` before running `runTelegram`
- checks out one pooled connection per DB script (read-only pool when configured,
  read-write pool otherwise) and projects into `AppWithConnection` before running `runDB`
- reads the real `extraContext` map from `DefaultApp`
- queues async work via `scheduleAsyncAction`

Tests use a third path, `runScenarioProgram`, which captures async requests instead of executing them.

## Async Worker Pool

`runAsync` in production queues the scenario via `scheduleAsyncAction` into one shared
`TQueue`. Worker loops drain that queue:

- `runAsyncWorker` — the single-worker drain loop (blocks forever; run it in a dedicated thread)
- `runAsyncWorkerPool :: Word -> (ScenarioProgram sc sl () -> RIO env ()) -> RIO env ()` —
  runs n competing copies of the same loop over the shared queue (work-stealing via
  competing `readTQueue`). n = 0 is clamped to 1 and n > 1024 to 1024, each with a
  warning log; cancelling or killing the calling thread stops all workers.

Each DB script executed by a worker checks out its own connection from the app pool, so
concurrent deferred tasks never share a PostgreSQL session (`test/AsyncWorkerPoolSpec.hs`
and `test/DbPoolSpec.hs` prove the parallelism, distinct connections, and error isolation).

Teardown order matters: cancel the worker threads first (in-flight `withResource`
checkouts then finish or are destroyed), then call `destroyAllResources` on both pools
(it does not wait for in-flight users) — otherwise in-flight scripts can race the
teardown. The demo app wires this in `withDemoApp`, with the pool size read from the
`ASYNC_WORKERS` env var (default 1).

## Timer Service

`runAsyncAfter delay program` defers a program instead of running it now. Production
registration goes through `scheduleTimedAction` into the `TimedActions` registry — a
`TVar` list of entries kept sorted by `(deadline, seq)` plus a separate `TVar` sequence
counter. `seq` is strictly increasing, so equal deadlines keep FIFO (registration) order.
Deferred actions are one-shot and fire exactly once, never before their deadline
(`delay <= 0` is picked up immediately); there is no cancel handle.

`runTimerService` must run in a dedicated thread — it blocks forever. Its arm/wait/drain
cycle:

1. **Arm** — read the head of the sorted registry (STM `retry` while it is empty).
2. **Wait** — compute the delay to that deadline and block on `registerDelay`. There are
   no time reads inside STM — deadlines are absolute `UTCTime` stamps taken at registration.
3. **Drain** — when the timer fires, one STM transaction pops the expired prefix (drain
   criterion: `deadline <= armed deadline`) and enqueues its programs into the shared
   `ScheduledActions` queue. Pop+enqueue is atomic, so actions are neither lost nor
   duplicated.
4. **Re-arm** — if the wait is interrupted early, the head is rechecked: an inserted entry
   with an earlier deadline re-arms the timer (the comparison is by `seq`, so equal
   deadlines never falsely re-arm); otherwise the loop retries until the armed deadline
   elapses.

Drained programs are executed by the ordinary async worker pool, not by the timer thread.
On shutdown the service thread is simply cancelled — unfired actions are dropped silently.

Both threads must be started:

```haskell
asyncThread <- async $ runRIO app $
    runAsyncWorkerPool 4 (runDefaultPerformer . run @Script @serviceLib)
timerThread <- async $ runRIO app runTimerService
```

The timer service only moves due programs into the queue — without the pool nothing
executes; forgot to start the timer service → deferred actions never fire.

## Review Checklist

- Are worker threads cancelled before `destroyAllResources` is called on the pools?
- Does the worker-pool size go through `runAsyncWorkerPool` (so the 0 / >1024 clamps apply)?
- Are the async worker pool AND the timer service both running (pool + timer service: without `runTimerService`, deferred `runAsyncAfter` actions never fire)?
