# Lazy Circus Reference: Extension And Integration

Read this when:

- adding a new Beam table or DB service instance
- registering in-process services with `ServiceHandler` and `IsInServiceLib`
- using `makeServiceLib` to generate service library boilerplate via TemplateHaskell
- adding a new effect language or public facade
- doing code review for cross-layer integration changes
- checking the detailed pitfalls and final review checklist

## Database Service Instances

To make a Beam table usable through `DBScript`, implement the service typeclasses from
`LazyCircus.DB.Service`.

### Required Classes

| Class | Responsibility |
|---|---|
| `IsInDb db table` | point to the concrete Beam table entity |
| `HasCreateService db table` | define inserts |
| `HasReadService db table` | define lookup id, select, and filtration |
| `HasUpdateService db table` | define update assignments |
| `HasDeleteService db table` | optional if default delete is enough |

### Canonical Pattern

```haskell
data MyTableT f = MyTable
    { myTableId :: Columnar f Int32
    , myTableName :: Columnar f Text
    }
    deriving (Generic, Beamable)

type MyTable = MyTableT Identity
type MyTableId = PrimaryKey MyTableT Identity

instance Table MyTableT where
    data PrimaryKey MyTableT f = MyTableId (Columnar f Int32)
        deriving (Generic, Beamable)
    primaryKey = MyTableId <$> myTableId

instance IsInDb MyDb MyTableT where
    getTargetTable = _myTableEntity

instance HasCreateService MyDb MyTableT where
    generateInsert db rows =
        insert (_myTableEntity db) $ insertExpressions $ map mkRow rows
      where
        mkRow row =
            MyTable
                { myTableId = maybe default_ val_ (myTableId row)
                , myTableName = maybe (val_ "") val_ (myTableName row)
                }

instance HasReadService MyDb MyTableT where
    type LId MyTableT = MyTableId
    generateSelect db (MyTableId i) = lookup_ (_myTableEntity db) (MyTableId i)
    generateFiltration _db (MyTableId i) row = myTableId row ==. val_ i

instance HasUpdateService MyDb MyTableT where
    generateAssigment _db patch row =
        mconcat
            [ maybe mempty (\v -> myTableName row <-. val_ v) (myTableName patch)
            ]

instance HasDeleteService MyDb MyTableT
```

### Important Details

#### `LId` Is The Lookup Key Type

This project uses an injective type family:

```haskell
type LId table = result | result -> table
```

That means each lookup-id type identifies exactly one table type. Keep the mapping stable and
specific.

#### Partial Updates Use `table Maybe`

Patch records for `update` and `updateMany` are sparse.

- `Nothing` means do not touch the field
- `Just value` means assign the field
- for nullable columns, `Just Nothing` means set SQL `NULL`

Example from the demo table:

```haskell
CircusAct
    { circusActId = Nothing
    , circusActName = Nothing
    , circusId = Nothing
    , circusActDescription = Just "New finale"
    , circusActAudienceReaction = Just Nothing
    }
```

#### `HasDeleteService` Often Needs No Custom Code

The default method uses `generateFiltration`, so an empty instance is enough in many cases.

#### Locking Reads Reuse `HasReadService`

`findLocked` and `findAllLocked` (the `SELECT ... FOR UPDATE` family) dispatch through the same `generateFiltration` used by `find` / `findAll`. No extra service instance is needed — once a table has `HasReadService`, locking reads work automatically. Just remember they must run inside `withTransaction` (see [effects.md](effects.md#row-locking)).

#### Use `dbScript` With An Explicit `DbMode`

```haskell
evalScript $ dbScript myDb ReadWrite $ create row
evalScript $ dbScript myDb ReadOnly $ find key
```

## Service Registration

Services are in-process workers that accept typed requests and return typed responses through
serialized channels. They are useful when you need a long-lived background worker that handles
requests one at a time — for example, a rate-limited external API client or a single-threaded
file writer.

### How It Works

Each service is a pair of `MVar` channels (a `Pipe`) guarded by a `QSem` semaphore. The caller
sends a request into the pipe and blocks until the worker posts a response. Because the
semaphore is set to 1, at most one request is in flight at any time.

### Step 1. Define Request And Response Types

```haskell
data SimpleRequest
    = Add Int Int
    | Subtract Int Int

data SimpleResponse = SimpleResult Int
    deriving (Show, Eq)
```

### Step 2. Provide A Failback Value

Every response type must implement `HasFailbackValue`. The failback value is returned to the
caller when the worker throws an exception.

```haskell
instance HasFailbackValue SimpleResponse where
    failbackValue = SimpleResult 0
```

### Step 3. Write The Handler Function

A plain function from request to `IO` response:

```haskell
handleSimpleRequest :: SimpleRequest -> IO SimpleResponse
handleSimpleRequest req =
    case req of
        Add x y      -> pure $ SimpleResult (x + y)
        Subtract x y -> pure $ SimpleResult (x - y)
```

### Step 4. Build A Service Library Type

Group all service handlers into a single record. This record is the `serviceLib` type parameter
of `DefaultApp`.

```haskell
data AllServices = AllServices
    { addService           :: ServiceHandler SimpleRequest SimpleResponse
    , addExpressionService :: ServiceHandler AddExpressionRequest AddExpressionResponse
    }
```

### Step 5. Implement `IsInServiceLib` Instances

For each request/response pair, implement `IsInServiceLib` so that `callService` can dispatch
to the correct handler:

```haskell
instance IsInServiceLib AllServices SimpleRequest SimpleResponse where
    callFromServiceLib allServices request =
        case request of
            Add x y      -> callService (addService allServices) (Add x y)
            Subtract x y -> callService (addService allServices) (Subtract x y)

instance IsInServiceLib AllServices AddExpressionRequest AddExpressionResponse where
    callFromServiceLib allServices = callService (addExpressionService allServices)
```

### Step 6. Create Handlers And Start Workers At Startup

`createService` returns a `(ServiceHandler, IO ())` pair — the handler and the worker action.
Create all handlers, build the library record, and fork the workers.

```haskell
import LazyCircus.App.Service
import Control.Concurrent (forkIO)

createAllServices :: IO AllServices
createAllServices = do
    (simpleHandler, simpleWorker) <- createService handleSimpleRequest
    (exprHandler, exprWorker) <- createService handleAddExpressionRequest
    _ <- forkIO simpleWorker
    _ <- forkIO exprWorker
    pure AllServices
        { addService = simpleHandler
        , addExpressionService = exprHandler
        }
```

### Step 7. Wire Into `DefaultAppConfig`

Pass the service library through `cfgServiceLib`:

```haskell
allServices <- createAllServices
let appConfig = DefaultAppConfig
        { cfgServiceLib = allServices
        , ...
        }
app <- newDefaultApp appConfig
```

When your application does not need services, use `NoServiceLib`:

```haskell
let appConfig = DefaultAppConfig
        { cfgServiceLib = NoServiceLib
        , ...
        }
```

### Step 8. Call From Scenarios

Inside a `ScenarioProgram`, use `callService` to dispatch to the correct worker:

```haskell
myScenario :: ScenarioProgram script AllServices ()
myScenario = do
    result <- callService (Add 3 4)
    logInfo $ "Got: " <> displayShow result
```

Alternatively, from any monad with `HasServiceLib` in scope, use `callViaServiceLib`:

```haskell
result <- callViaServiceLib (Add 3 4)
```

### Checklist For Service Registration (Manual)

- request and response types defined
- `HasFailbackValue` instance for each response type
- handler function `request -> IO response`
- service library record holding `ServiceHandler` fields
- `IsInServiceLib` instance for each request/response pair
- `createService` called at startup; workers forked
- library record passed to `cfgServiceLib` in `DefaultAppConfig`
- `callService` used from scenarios or `callViaServiceLib` from reader context

## Service Library via TemplateHaskell

The manual steps above (4–6) can be replaced by a single Template Haskell macro call.
`makeServiceLib` generates the service library data type, a config record, `IsInServiceLib`
instances, a builder function, and optional tool-call plumbing for AI integration — all from
a list of request/response/tool-spec triples.

### When To Use TH vs Manual

Use TH when you have multiple service pairs and want to avoid boilerplate. Use the manual
approach when you need custom logic in `IsInServiceLib` instances or when adding TH is not
desirable.

### Step 1. Define Request And Response Types + HasFailbackValue

Same as the manual approach (steps 1–3 above).

When tool specs will be provided, also add `FromJSON` for request types and `ToJSON` for
response types (required by the generated `FromJSON ToolCall` instance and
`encodeToolResponse` function).

### Step 2. Call `makeServiceLib`

```haskell
{-# LANGUAGE TemplateHaskell #-}

import LazyCircus.App.Service.TH (makeServiceLib)

-- Must appear AFTER type definitions, HasFailbackValue, FromJSON, and ToJSON instances
makeServiceLib "AllServices"
    [ (''SimpleRequest, ''SimpleResponse,
        [('Add, "add_numbers", "Adds two numbers together")
        ,('Subtract, "subtract_numbers", "Subtracts two numbers")
        ])
    , (''AddExpressionRequest, ''AddExpressionResponse,
        [('AddExpressionRequest, "add_expression", "Add an expression")
        ])
    ]
```

Each entry is a triple `(''RequestType, ''ResponseType, toolSpecs)` where `toolSpecs` is a
list of `(ConstructorName, "tool_name_string", "human-readable description")`. Pass `[]` for
services that do not need tool-call plumbing.

This generates up to fourteen things:

1. **Service library type** — `data AllServices = AllServices { simpleRequestService :: ServiceHandler SimpleRequest SimpleResponse, ... }`
2. **Config type** — `data AllServicesConfig m = AllServicesConfig { simpleRequest :: SimpleRequest -> m SimpleResponse, ... }`
3. **`IsInServiceLib` instances** — one per pair, implementing `callFromServiceLib`
4. **Builder function** — `mkAllServices :: (MonadUnliftIO m, ...) => AllServicesConfig m -> m (AllServices, [m ()])`
5. **Tool enumeration type** — `data AllServicesTool = AddTool | SubtractTool | ... deriving (Enum, Bounded, ...)` (empty type when no specs)
6. **`toolInfo` function** — maps enum values to `ToolDescription`
7. **`allToolDescriptions`** — `[ToolDescription]` collecting all tools
8. **`ToolCall` sum type** — `data AllServicesToolCall = SimpleRequestToolCall Text SimpleRequest | ...` (when specs present)
9. **`ToolResponse` sum type** — `data AllServicesToolResponse = SimpleResponseToolResponse SimpleResponse | ...` (when specs present)
10. **`FromJSON` instance for `ToolCall`** — dispatches on `"tool_name"` field (when specs present)
11. **`executeToolCall` function** — dispatches a tool call to the correct service handler (when specs present)
12. **`toolCallName` function** — extracts the tool name from a `ToolCall` (when specs present)
13. **`encodeToolResponse` function** — encodes a `ToolResponse` as JSON with tool name (when specs present)
14. **Smart constructors** `aiScriptWithAll` and `aiScriptWith` — wrap AI scripts with tool descriptions (when specs present)

### Step 3. Write Handler Functions

Same as the manual approach. Handlers can be any `RequestType -> m ResponseType` function,
including curried functions with arbitrary constraints:

```haskell
handleSimple :: (MonadIO m) => SimpleRequest -> m SimpleResponse
handleSimple (Add x y)      = pure $ SimpleResult (x + y)
handleSimple (Subtract x y) = pure $ SimpleResult (x - y)
```

### Step 4. Build And Start Services At Startup

Fill a config record with handler functions, call `mkAllServices`, and start workers:

```haskell
import LazyCircus.App.Service (runAllWorkers, NoServiceLib(..))

main :: IO ()
main = do
    let config = AllServicesConfig
            { simpleRequest = handleSimple
            , addExpressionRequest = handleAddExpressionRequest
            }
    (services, workers) <- mkAllServices config
    _ <- runAllWorkers workers
    app <- newDefaultApp DefaultAppConfig{ cfgServiceLib = services, ... }
    ...
```

`runAllWorkers :: MonadUnliftIO m => [m ()] -> m [Async ()]` forks each worker via `async`
and returns the handles. Callers can use `mapM_ cancel` for graceful shutdown or discard
the handles if fire-and-forget is desired.

### Using Tool-Aware AI Scripts

When tool specs are provided, the TH macro generates `aiScriptWithAll` and `aiScriptWith`:

```haskell
-- Pass all registered tools to the AI
evalScript $ aiScriptWithAll $ ask myRequest

-- Pass a subset of tools
evalScript $ aiScriptWith [AddTool, SubtractTool] $ ask myRequest
```

### Pitfalls For TH Service Library

- **`HasFailbackValue` is required** for every response type before the TH splice. If you
  forget it, you get a compilation error about a missing instance.
- **`FromJSON`/`ToJSON` are required** for request/response types when tool specs are provided.
  The generated `FromJSON ToolCall` instance needs `FromJSON` on the request type, and
  `encodeToolResponse` needs `ToJSON` on the response type.
- **Types must be defined before the splice.** `''SimpleRequest` references the type, so the
  `data SimpleRequest` declaration must appear above the `makeServiceLib` call.
- **No duplicate request types.** Passing `(''SimpleRequest, ''A, _)` and `(''SimpleRequest, ''B, _)`
  causes a compile-time `fail` from the macro.
- **No duplicate enum constructor names.** Constructor names in tool specs must be unique across
  all request types to avoid collisions in the generated tool enum.
- **No duplicate tool-name strings.** Tool name strings must be unique across all specs.
- **Separate module for TH splice recommended.** Import only type names (no constructors) into
  the TH module to avoid name clashes between request constructors and generated enum constructors.
  See `SimpleServiceLib.hs` in the `common/` directory for the canonical pattern.
- **Redundant constraint warning.** GHC may emit `-Wredundant-constraints` for the generated
  `mkAllServices` because `HasFailbackValue` constraints are implied by the instances. This is
  harmless.

### Checklist For TH Service Registration

- request and response types defined
- `HasFailbackValue` instance for each response type
- `FromJSON` for request types and `ToJSON` for response types (when tool specs are provided)
- handler functions written
- `makeServiceLib` splice placed after type definitions, instances, and in a separate module to avoid constructor name clashes
- config record filled with handler functions
- `mkAllServices` called at startup
- `runAllWorkers` called to start all workers
- library record passed to `cfgServiceLib` in `DefaultAppConfig`
- tool specs use unique constructor names and unique tool-name strings

## Adding A New Effect

To add a new scene language, follow the same structure as DB, Telegram, AI, Mail, and HTTP.

### Step 1. Define The Functor And Smart Constructors

Create `src/LazyCircus/Scene/MyEffect/Lang.hs`.

```haskell
module LazyCircus.Scene.MyEffect.Lang where

import Control.Monad.Free.Church (F)
import Control.Monad.Free.Church qualified as CF
import Control.Monad.Free.Class qualified as MF
import LazyCircus.Scene.Log (HasLogLang (..), LogLangF)
import RIO

liftFC :: (Functor f, MF.MonadFree f m) => f a -> m a
liftFC = CF.liftF

data MyEffectF a where
    DoSomething :: Text -> (Result -> a) -> MyEffectF a
    MyEffectLog :: LogLangF MyEffect b -> (b -> a) -> MyEffectF a

instance Functor MyEffectF where
    fmap f (DoSomething input next) = DoSomething input (f . next)
    fmap f (MyEffectLog logOp next) = MyEffectLog logOp (f . next)

instance HasLogLang MyEffectF MyEffect where
    embedLog logOp = MyEffectLog logOp id

doSomething :: (MF.MonadFree MyEffectF m) => Text -> m Result
doSomething input = liftFC $ DoSomething input id

type MyEffect = F MyEffectF
```

### Step 2. Define The Performer Class And Runner

Create `src/LazyCircus/Scene/MyEffect/Class.hs`.

```haskell
module LazyCircus.Scene.MyEffect.Class where

import Control.Monad.Free.Church (iterM)
import LazyCircus.Scene.Log (handleLogLang)
import LazyCircus.Scene.MyEffect.Lang

class Monad m => MyEffectPerformer m where
    doSomething' :: Text -> m Result

runMyEffect ::
    ( MyEffectPerformer m
    , HasLogQueue env
    , HasLoggingContext env
    , MonadReader env m
    , MonadIO m
    ) =>
    MyEffect a -> m a
runMyEffect = iterM go
  where
    go (DoSomething input next) = do
        result <- doSomething' input
        next result
    go (MyEffectLog logOp next) =
        handleLogLang "MyEffect" runMyEffect (fmap next logOp)
```

### Step 3. Add It To `Script` And The Scenario Performer

Update `LazyCircus.Script`:

```haskell
data Script b where
    ...
    MyEffectDef :: MyEffect b -> Script b
```

Update `LazyCircus.Performer` dispatch:

```haskell
instance (...) => ScenarioPerformer script serviceLib m where
    onEvalScript (MyEffectDef scr) = runMyEffect scr
    ...
```

Update the default performer if the new effect needs a special environment projection.

### Step 4. Add The Public Facade And Optional Top-Level Smart Constructor

Public effects in this repository usually also get a stable facade module such as
`LazyCircus.Scene.Telegram`, `LazyCircus.Scene.AI`, `LazyCircus.Scene.Mail`,
`LazyCircus.Scene.DB`, or `LazyCircus.Scene.HTTP`.

Typical facade shape:

```haskell
module LazyCircus.Scene.MyEffect (
    module LazyCircus.Scene.MyEffect.Class,
    module LazyCircus.Scene.MyEffect.Lang,
    slogInfo,
    slogWarn,
    slogError,
    slogSensitive,
    swithLogCtx,
) where

import LazyCircus.Scene.Log (slogError, slogInfo, slogSensitive, slogWarn, swithLogCtx)
import LazyCircus.Scene.MyEffect.Class
import LazyCircus.Scene.MyEffect.Lang
```

If the effect should have a convenience wrapper like `tgScript`, `mailScript`, `aiScript`,
`httpScript`, or `dbScript`, also update `LazyCircus.hs`. Add a new one only when the public API
genuinely benefits from it.

### Checklist For New Effects

- functor GADT exists
- `Functor` instance exists
- `HasLogLang` instance exists
- smart constructors exist
- performer typeclass exists
- runner via `iterM` exists
- `Script` constructor added
- `ScenarioPerformer script serviceLib` dispatch updated
- stable `LazyCircus.Scene.MyEffect` facade added when the effect is public
- optional top-level smart constructor added only when the effect should mirror `tgScript`, `mailScript`, `aiScript`, or `httpScript`
- default and test runtimes updated as needed

## Detailed Pitfalls

### 1. Mixing Scenario Logging With Scene Logging

Problem:

- using `logInfo` inside a DB or Telegram script
- using `slogInfo` in a `ScenarioProgram`

Fix:

- `logInfo` family is for `ScenarioProgram`
- `slogInfo` family is for scene languages

### 2. Forgetting To Wrap Subprograms In `Script`

Problem:

```haskell
evalScript $ sendMessage req
```

This is wrong because `sendMessage req` is a `TelegramScript`, not a `Script`.

Fix:

```haskell
evalScript $ tgScript "demo-bot" $ sendMessage req
```

### 3. Expecting Separate Read/Write DB Constructors

Problem:

- trying to call something like `rwDbScript` or `roDbScript`

Fix:

There is one DB smart constructor, `dbScript`, which takes the `DbMode`
(`ReadWrite` / `ReadOnly`) as its second argument:

```haskell
evalScript $ dbScript simpleDb ReadWrite $ find key
```

(`DBScriptDef` is the underlying `Script` constructor and remains available via
`Script(..)`.)

### 4. Using `ReadOnly` For Writes

Problem:

- `create`, `update`, `updateMany`, and `delete` throw `DbReadOnlyViolation` in `ReadOnly`

Fix:

- use `ReadWrite` for mutating operations
- keep `ReadOnly` for reads only

### 5. Assuming `create` Returns A Plain Row

Problem:

- writing `act <- create row` and then treating `act` as a non-`Maybe` value

Fix:

- `create` and `createAsIs` return `Maybe row`
- branch explicitly or use helpers like `forM` or `maybe`

### 6. Assuming Tests Mock The DB

Problem:

- expecting DB operations to be fake inside `TestInterpreter`

Fix:

- DB still uses a real PostgreSQL database in this repository (each DB script checks out its own connection from the app's pool)
- set up the test DB correctly before running DB tests

### 7. Assuming Test Async Work Is Executed

Problem:

- expecting side effects from `runAsync` during tests

Fix:

- test interpreter only records scheduled scenarios
- assert with `readScheduledScenarios`

### 8. Forgetting `HasLogLang` When Adding A New Effect

Problem:

- new effect cannot use `slogInfo`
- log handling is inconsistent with other languages

Fix:

- add a log constructor to the functor
- implement `HasLogLang`
- route logs through `handleLogLang`

### 9. Misunderstanding Patch Semantics For Nullable Fields

Problem:

- expecting `Nothing` in `table Maybe` to set SQL `NULL`

Fix:

- `Nothing` means leave field unchanged
- `Just Nothing` means set nullable field to `NULL`
- `Just (Just x)` means set nullable field to `x`

### 10. Forgetting `hpack` Before Build Or Test

Problem:

- stale cabal metadata after changing modules

Fix:

Run:

```bash
hpack
stack build
```

### 11. Catching Everything With `runSafely` Too Early

Problem:

- scenario errors disappear into `Either` without useful handling

Fix:

- use `runSafely` only around the part that should degrade gracefully
- log and branch explicitly on the result

### 12. TH Splice Before Type Definitions

Problem:

- `makeServiceLib` fails because `''RequestType` is not in scope

Fix:

- place the `makeServiceLib` splice after all request/response `data` declarations
- place it after all `HasFailbackValue` instances

### 13. Duplicate Request Types In makeServiceLib

Problem:

- passing `(''Req, ''A, _)` and `(''Req, ''B, _)` causes a confusing type error

Fix:

- `makeServiceLib` detects duplicates and calls `fail` with a clear message
- ensure each request type appears exactly once in the triple list

### 14. Duplicate Enum Constructor Names In Tool Specs

Problem:

- two tool specs across different request types using the same constructor name (e.g., `('Add, ...)` in two places) causes a compile error

Fix:

- `makeServiceLib` detects duplicate enum constructor names and fails with a clear message
- ensure each constructor name in tool specs is unique across all request types

### 15. Missing FromJSON/ToJSON When Using Tool Specs

Problem:

- `makeServiceLib` with non-empty tool specs generates a `FromJSON ToolCall` instance that requires `FromJSON` on the request type
- `encodeToolResponse` requires `ToJSON` on the response type

Fix:

- add `FromJSON` instance for each request type that has tool specs
- add `ToJSON` instance for each response type that has tool specs

### 16. Constructor Name Clashes Between Request And Tool Enum

Problem:

- tool spec constructor names are used as enum constructors in the generated `{Lib}Tool` type, which can clash with the original request constructors if both are in scope

Fix:

- place the `makeServiceLib` splice in a separate module that imports only type names (no constructors) from the request/response module
- see `SimpleServiceLib.hs` for the canonical pattern

## Review Checklist

1. Is code placed in the right layer: scene vs scenario vs performer?
2. Are all new exported functions and types documented with Haddock contracts?
3. If a new effect was added, was `Script` dispatch updated everywhere?
4. If DB tables changed, were all required service instances implemented?
5. Are scenario logs using `logInfo` and scene logs using `slogInfo`?
6. Does the interpreter preserve logging context correctly?
7. Are async paths tested via captured scheduled scenarios?
8. Was `hpack` run before build and test?
9. If using `makeServiceLib`, are all `HasFailbackValue` instances defined before the splice?
10. If using `makeServiceLib`, are there no duplicate request types in the triple list?
11. If using `makeServiceLib` with tool specs, are `FromJSON`/`ToJSON` instances provided?
12. If using `makeServiceLib` with tool specs, are constructor names and tool-name strings unique?
13. Is the TH splice in a separate module to avoid constructor name clashes?