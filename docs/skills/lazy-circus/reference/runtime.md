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

## Review Checklist

- Are worker threads cancelled before `destroyAllResources` is called on the pools?
- Does the worker-pool size go through `runAsyncWorkerPool` (so the 0 / >1024 clamps apply)?
