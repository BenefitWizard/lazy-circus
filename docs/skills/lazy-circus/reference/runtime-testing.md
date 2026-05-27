# Lazy Circus Reference: Runtime And Testing

Read this when:

- debugging interpreter behavior
- working with `DefaultPerformer`, `evalScriptDefault`, or environment projection
- reasoning about async execution, extra context, bot lookup, or test semantics

## Runtimes And Environments

Lazy Circus relies on environment capabilities exposed via small lens-based typeclasses.

### Main Production Runtime

`LazyCircus.Performer.Default` defines:

```haskell
newtype DefaultPerformer env a = DefaultPerformer
    { runDefaultPerformer :: RIO env a }
```

`runDefaultScenario :: ScenarioProgram Script serviceLib a -> DefaultPerformer (DefaultApp serviceLib) a`

Note: `runDefaultScenario` is not currently exported. Production scenarios are run via the generic `run` function:
`runRIO app $ runDefaultPerformer $ run @Script @serviceLib myScenario`

`DefaultApp serviceLib` contains:

- primary PostgreSQL connection
- optional read-only PostgreSQL connection
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

### Wrapper Environments

#### `AppWithConnection`

Module: `LazyCircus.DB.WithConnection`

Use this when one interpreter must run against a selected DB connection while preserving access
to the rest of the application environment.

The default performer uses it to choose between read-write and read-only DB connections.

#### `AppWithBotEnv`

Module: `LazyCircus.Telegram.Types`

Use this when a Telegram script needs one specific bot environment.

The default performer looks up the bot by name and projects into `AppWithBotEnv` before running
`runTelegram`.

### `changeEnv`

`changeEnv` projects one performer into another environment.

```haskell
changeEnv :: (outer -> inner) -> DefaultPerformer inner a -> DefaultPerformer outer a
```

This is not a lens update. It is a pure projection from outer environment to inner environment.

### Dispatch Paths

There are two important execution entry points:

1. `run` from `LazyCircus.Scenario` together with the generic `ScenarioPerformer Script serviceLib`
   instance in `LazyCircus.Performer`
2. `evalScriptDefault` from `LazyCircus.Performer.Default` — the production dispatch that
   pattern-matches on `Script` variants

The generic `ScenarioPerformer Script serviceLib` instance:

- dispatches `Script` by calling `runTelegram`, `runMail`, `runAI`, `runDB`, and `runHTTP`
- uses `async` directly for `runAsync`
- returns `mempty` from `getExtraContext'`

The default performer's `evalScriptDefault` is the production-specific dispatch. It:

- looks up the requested Telegram bot name and throws `NoBotConfigured` when absent
- projects into `AppWithBotEnv` before running `runTelegram`
- projects into `AppWithConnection` before running `runDB`
- uses the read-only PostgreSQL connection when configured and falls back to the primary one otherwise
- reads the real `extraContext` map from `DefaultApp`
- queues async work via `scheduleAsyncAction`

Tests use a third path, `runScenarioProgram`, which captures async requests instead of executing them.

## Testing

Module: `LazyCircus.Testing.Performer`

Use the testing performer when you want to run scenarios with mocked logging, Telegram,
mail, AI, and async scheduling.

### Shared-Runner Architecture

The test runtime is not a separate reimplementation of scenario semantics. It keeps the same
shared-runner architecture as production:

- `ScenarioProgram` still runs through the normal scenario interpreter machinery
- top-level `Script` dispatch still chooses DB, Telegram, Mail, AI, and HTTP branches the same way
- environment projection still happens through wrappers like `AppWithConnection` and `AppWithBotEnv`

The main difference is the capability layer behind that runner:

- DB capability uses the real configured connection
- Telegram capability is replaced with capture-oriented mocks
- Mail capability reuses real mail construction but captures sends
- AI capability returns mock values (`Nothing` by default)
- HTTP capability executes real servant-client requests via the configured manager and base URL
- async capability captures scheduled scenarios instead of executing them
- logging capability captures structured entries instead of draining the production queue

This means tests exercise the same orchestration path as production while swapping effectful
capabilities at the edges.

### Key Types

| Type | Purpose |
|---|---|
| `Mocks serviceLib` | collected mock state (Tg requests, mails, logs, async tasks) |
| `TgMock` | Telegram mock with configurable response queue |
| `MailMock` | Mail mock for capturing sent mails |
| `EnvWithMocks serviceLib` | environment extended with mock state |
| `TestInterpreter serviceLib a` | the test-performer monad |
| `OnSendMessageRequest` | callback type for custom Telegram send handling |

### Main Helpers

| Function | Purpose |
|---|---|
| `makeMocks` | allocate a fresh mock state |
| `runWithMocks` | run with caller-supplied app and mocks |
| `runWithDefaultMocks` | allocate mocks and run |
| `runScenarioProgram` | execute a `ScenarioProgram Script` in `TestInterpreter` |
| `runScript` | execute one top-level `Script` |
| `readTgRequests` | read captured immediate Telegram sends |
| `readScheduledTgRequests` | read captured scheduled Telegram sends |
| `readLog` | read captured log payloads |
| `readLogWithContext` | read contextualized log messages |
| `readSentMails` | read outgoing mails |
| `readScheduledScenarios` | read captured async scenario requests |

Also useful for custom harnesses:

- `runInsideWithMocks` and `runInsideWithDefaultMocks` run tests inside `RIO DefaultApp`
- `discardMocks` drops the collected capture state when only the result matters
- `createTgMock`, `createSimpleTgMock`, and `createSimpleMailMock` help build custom mock setups

### Mocked Sub-Language Runners

These run one sub-language in isolation with mock logging:

| Function | Scope |
|---|---|
| `runDBWithMockLogging` | DB script with captured logs |
| `runTelegramWithMockLogging` | Telegram script with captured logs |

### Mock Behavior Summary

| Effect | Test behavior |
|---|---|
| Telegram `sendMessage` | captures `WithImportance SendMessageRequest` values and returns canned/default response |
| Telegram scheduled sends | captured in a separate list |
| Telegram missing bot | throws `NoBotConfigured` exactly like production dispatch |
| Telegram `getBotName` | returns the supplied bot name |
| Telegram file loading | not implemented and throws |
| Telegram `editMessageText` | always returns `Nothing` |
| Mail `sendMail` | captures mail values |
| Mail `makeMail` | uses real mail construction from env creds |
| AI `ask` | always returns `Nothing` |
| HTTP `runClient` | real execution via servant-client against target base URL |
| DB | runs against a real DB connection |
| Logging | captured in refs, not pushed to shared queue |
| `runAsync` | captures scenario without executing it |

### Typical Test Pattern

```haskell
spec :: Spec
spec = do
    it "sends a telegram message" $ do
        (mocks, _) <- runWithDefaultMocks app $ do
            runScenarioProgram myScenario

        requests <- readTgRequests mocks
        requests `shouldSatisfy` (not . null)

        logs <- readLog mocks
        logs `shouldSatisfy` elem (AppLogMsg "Scenario completed")
```

When no services are needed, use `NoServiceLib`:

```haskell
import LazyCircus.App.Service (NoServiceLib)

app :: DefaultApp NoServiceLib
```

### DB Integration Tests

This repository uses a real PostgreSQL database in DB tests.

Important project behavior:

- tests expect PostgreSQL at `127.0.0.1:5432`
- user `postgres`, password `my_password` is used for bootstrap
- app user `lazy_circus_app`, password `my_password`
- tests recreate `lazy_circus_test`
- migrations are plain SQL from `Common.migration`

### Verifying Async Work

Because test `runAsync` only captures requests, assert on scheduled scenarios instead of side
effects.

```haskell
it "schedules background cleanup" $ do
    (mocks, _) <- runWithDefaultMocks app $ do
        runScenarioProgram myScenario

    asyncs <- readScheduledScenarios mocks
    length asyncs `shouldBe` 1
```

If you want to verify the deferred effect itself, explicitly run the captured scenario later with
the same test runtime and then inspect the corresponding capture buffer.

### Verifying Log Context

Use `readLogWithContext` when the test cares about tags, call-site data, or enriched entries.

Typical checks include:

- scenario logs carrying `lang = "Scenario"`
- custom keys added via `withLogContext`
- sub-language logs preserving the outer context and adding their own language tag
- non-empty call-site metadata when emitted through standard logging helpers

### Verifying Telegram Capture

When a bot is configured in the app env:

- use `readTgRequests` for immediate `sendMessage` capture
- use `readScheduledTgRequests` for deferred Telegram queue capture
- use `getBotName` to verify dispatch selected the expected bot environment

When no bot is configured for a requested name, tests should assert `NoBotConfigured` rather than
expecting a silent no-op.
