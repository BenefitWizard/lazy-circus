# Lazy Circus Reference: Extension And Integration

Read this when:

- adding a new Beam table or DB service instance
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

#### Use `DBScriptDef` With An Explicit `DbMode`

```haskell
evalScript $ DBScriptDef myDb ReadWrite $ create row
evalScript $ DBScriptDef myDb ReadOnly $ find key
```

## Adding A New Effect

To add a new scene language, follow the same structure as DB, Telegram, AI, and Mail.

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
instance (...) => ScenarioPerformer Script m where
    onEvalScript (MyEffectDef scr) = runMyEffect scr
    ...
```

Update the default performer if the new effect needs a special environment projection.

### Step 4. Add The Public Facade And Optional Top-Level Smart Constructor

Public effects in this repository usually also get a stable facade module such as
`LazyCircus.Scene.Telegram`, `LazyCircus.Scene.AI`, `LazyCircus.Scene.Mail`, or
`LazyCircus.Scene.DB`.

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

If the effect should have a convenience wrapper like `tgScript`, `mailScript`, or `aiScript`,
also update `LazyCircus.hs`. There is intentionally no DB smart constructor, so add a new one
only when the public API genuinely benefits from it.

### Checklist For New Effects

- functor GADT exists
- `Functor` instance exists
- `HasLogLang` instance exists
- smart constructors exist
- performer typeclass exists
- runner via `iterM` exists
- `Script` constructor added
- `ScenarioPerformer Script` dispatch updated
- stable `LazyCircus.Scene.MyEffect` facade added when the effect is public
- optional top-level smart constructor added only when the effect should mirror `tgScript`, `mailScript`, or `aiScript`
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

### 3. Expecting A DB Smart Constructor That Does Not Exist

Problem:

- trying to call something like `dbScript` or `rwDbScript`

Fix:

Use the constructor directly:

```haskell
evalScript $ DBScriptDef simpleDb ReadWrite $ find key
```

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

- DB still uses a real PostgreSQL connection in this repository
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

## Review Checklist

1. Is code placed in the right layer: scene vs scenario vs performer?
2. Are all new exported functions and types documented with Haddock contracts?
3. If a new effect was added, was `Script` dispatch updated everywhere?
4. If DB tables changed, were all required service instances implemented?
5. Are scenario logs using `logInfo` and scene logs using `slogInfo`?
6. Does the interpreter preserve logging context correctly?
7. Are async paths tested via captured scheduled scenarios?
8. Was `hpack` run before build and test?