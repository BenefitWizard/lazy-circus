# Lazy Circus Reference: DB Effect

Read this when:

- using or reviewing `DBScript` (module `LazyCircus.Scene.DB.Lang`)
- deciding between `dbScript`, `withTransaction`, and `withTransactionRLS`
- using locking reads (`findLocked` / `findAllLocked`)
- reasoning about `ReadOnly` mode, connection pools, or RLS contexts

## Contents

- Operations
- Row Locking
- Transactions, Autocommit, And RLS
- Review Checklist

## Operations

Program type:

```haskell
type DBScript db = F (DBLangF db)
```

Main operations:

| Function | Result |
|---|---|
| `create` | `Maybe` first inserted row |
| `createMany` | all inserted rows |
| `createAsIs` / `createManyAsIs` | `Maybe` first inserted row / all inserted rows |
| `find` | `Maybe row` |
| `findAll` | `[row]` |
| `findLocked` | `Maybe row` while acquiring a row lock |
| `findAllLocked` | `[row]` while acquiring a row lock |
| `update` / `updateMany` | updated rows (sparse patch — see below) |
| `delete` | `()` |
| `runQuery` | Beam query result |
| `rawQuery` | decoded SQL rows |
| `withTransaction` | transactional nested script |
| `withTransactionRLS` | transaction with row-level security context |

Signatures (module `LazyCircus.Scene.DB.Lang`; `Identity` = the concrete row type):

```haskell
create             :: HasCreateService db table => table Maybe   -> DBScript db (Maybe (table Identity))
createMany         :: HasCreateService db table => [table Maybe] -> DBScript db [table Identity]
createAsIs         :: HasCreateService db table => table Identity -> DBScript db (Maybe (table Identity))
find               :: HasReadService  db table => LId table -> DBScript db (Maybe (table Identity))
findAll            :: HasReadService  db table => LId table -> DBScript db [table Identity]
findLocked         :: HasReadService  db table => LockSpec -> LId table -> DBScript db (Maybe (table Identity))
findAllLocked      :: HasReadService  db table => LockSpec -> LId table -> DBScript db [table Identity]
update             :: HasUpdateService db table => table Maybe -> LId table   -> DBScript db [table Identity]
updateMany         :: HasUpdateService db table => table Maybe -> [LId table] -> DBScript db [table Identity]
delete             :: HasDeleteService db table => LId table -> DBScript db ()
runQuery           :: (PgDB db -> Pg b) -> DBScript db b
rawQuery           :: FromRow b => Query -> [Action] -> DBScript db [b]
withTransaction    :: DBScript db b -> DBScript db b
withTransactionRLS :: RLSContext -> DBScript db b -> DBScript db b
```

`RLSContext` (module `LazyCircus.Scene.DB.RLS`) is a newtype over `[(Text, Text)]`
with `Monoid`/`Semigroup`: build one directly, e.g. `RLSContext [("circus_id", "42")]`,
or combine contexts with `<>` / `mempty`.

Example:

```haskell
createAndUpdate :: DBScript SimpleDb (Maybe CircusAct)
createAndUpdate = withTransaction $ do
    mAct <- create (CircusAct Nothing (Just "Aerial") (Just 7) (Just "Demo") Nothing)
    forM mAct $ \act -> do
        let
            patch =
                CircusAct
                    { circusActId = Nothing
                    , circusActName = Nothing
                    , circusId = Nothing
                    , circusActDescription = Just "Updated"
                    , circusActAudienceReaction = Nothing
                    }
        _ <- update patch (CircusActId $ circusActId act)
        pure act
```

Important DB semantics:

- each DB script checks out one connection from the app's PostgreSQL pool for its entire duration — concurrent scripts (including async workers) run on separate connections, so `withTransaction` and RLS settings never interleave across scripts; `ReadOnly` uses the read-only pool when configured, falling back to the read-write pool
- `create` and `createAsIs` use `listToMaybe`; if the interpreter returns `[]`, they yield `Nothing`
- write operations are blocked in `ReadOnly` mode by `DbReadOnlyViolation`
- `update` / `updateMany` patches are sparse `table Maybe` records: `Nothing` leaves the column untouched, `Just value` assigns it, and for a nullable column `Just Nothing` assigns SQL `NULL` (`Just (Just x)` assigns `x`). The returned list holds the actually updated rows; `[]` means nothing matched — a wrong key OR an RLS policy filtering the row out — and is NOT an error. See [extension.md](extension.md#partial-updates-use-table-maybe) for the instance side (`generateAssigment`).
- `withTransactionRLS` applies `SET LOCAL rls.<key> = ?` inside the transaction; the context is built directly, e.g. `RLSContext [("circus_id", "42")]`, and contexts combine with `<>` / `mempty`

## Row Locking

`findLocked` and `findAllLocked` acquire a row lock (the Postgres `FOR UPDATE` family) on the matched rows. They take a `LockSpec` that pairs a lock strength with a waiting policy:

```haskell
data LockStrength
    = LockUpdate       -- ^ FOR UPDATE
    | LockNoKeyUpdate  -- ^ FOR NO KEY UPDATE
    | LockShare        -- ^ FOR SHARE
    | LockKeyShare     -- ^ FOR KEY SHARE

data LockWaiting
    = WaitDefault     -- ^ block until the lock holder commits/aborts
    | WaitNoWait      -- ^ NOWAIT
    | WaitSkipLocked  -- ^ SKIP LOCKED

data LockSpec = LockSpec
    { lockSpecStrength :: LockStrength
    , lockSpecWaiting  :: LockWaiting
    }

defaultLock :: LockSpec   -- LockUpdate + WaitDefault
```

Locking semantics:

- PRE-CONTRACT: a locking read MUST run inside `withTransaction`; `FOR UPDATE` locks are released at COMMIT/ROLLBACK. Outside a transaction Postgres auto-commits each statement and the lock is a no-op.
- `WaitNoWait` surfaces a contended row as a thrown `SqlError` (Postgres error `55P03`), not as an empty result.
- `WaitSkipLocked` makes an empty result ambiguous: it means either "no such row" OR "row exists but was skipped because another transaction holds a conflicting lock".
- locking reads are allowed in `ReadOnly` mode (they do not mutate); they reuse `HasReadService`, so no extra service instances are required.

Example:

```haskell
reserveAct :: Int32 -> DBScript SimpleDb (Maybe CircusAct)
reserveAct actId = withTransaction $ do
    findLocked defaultLock (CircusActId actId)
```

## Transactions, Autocommit, And RLS

Every statement of a DB script that is NOT inside `withTransaction` runs in Postgres
autocommit mode on the script's checked-out connection — each statement is its own
transaction. Consequences:

- `withTransactionRLS` is the ONLY way to establish an RLS context: it opens a
  transaction and issues `SET LOCAL rls.<key> = ?`, and a `SET LOCAL` cannot exist
  outside a transaction. A standalone script — a `dbScript` body with no transaction
  wrapper — therefore NEVER carries an RLS context.
- Under an RLS policy that fails closed when the setting is missing, such a standalone
  script silently sees zero rows: `update` / `updateMany` return `[]`, `find` returns
  `Nothing`, `findAll` returns `[]`. Nothing throws. Typical symptom: a cache/state
  write appears to succeed but nothing lands in the table, and downstream logic waits
  on data that never appears.
- RULE: a DB script that touches an RLS-protected table MUST self-wrap in
  `withTransactionRLS ctx` (the caller cannot inject the context later). Plain
  `withTransaction` is still preferred for any multi-statement read-modify-write
  sequence, policy or not, for atomicity.
- The demo policy `circus_acts_circus_rls` in `common/Common.hs` fails OPEN — a
  missing `rls.circus_id` makes the policy `TRUE` — so the in-repo demo and its
  tests cannot reproduce this trap. Check your own project's policies for the
  fail-open vs fail-closed `CASE` shape before relying on unwrapped scripts.

```haskell
-- Standalone write to an RLS-protected table — MUST self-wrap:
writeState :: Int32 -> Text -> DBScript SimpleDb [CircusAct]
writeState circusId newDescription =
    withTransactionRLS (rlsCircusId circusId) $
        update patch (CircusActId 1)
  where
    patch =
        CircusAct
            { circusActId = Nothing
            , circusActName = Nothing
            , circusId = Nothing
            , circusActDescription = Just newDescription
            , circusActAudienceReaction = Nothing
            }
```

Embedding into a scenario:

```haskell
evalScript $ dbScript simpleDb ReadWrite $ find (CircusActId 42)
```

There is no need to use `DBScriptDef` directly — the `dbScript` smart constructor
(from `LazyCircus`) is the idiomatic wrapper, mirroring `tgScript` / `mailScript` /
`aiScript` / `httpScript`. `DBScriptDef` remains available via `Script(..)`.

## Review Checklist

- Are locking reads (`findLocked` / `findAllLocked`) inside `withTransaction`, and is the `WaitNoWait` throw / `WaitSkipLocked` empty-result ambiguity handled?
- Do `update` / `updateMany` patches use the right `Maybe` level (`Nothing` skip / `Just Nothing` → SQL `NULL` / `Just (Just x)` → value)?
- Is an empty updated-rows result handled rather than discarded?
- Do standalone scripts touching RLS-protected tables self-wrap in `withTransactionRLS`?
