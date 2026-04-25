# AI Tool Plumbing — Plan

Date: 2025-04-25

## Goal

Extend `AIScriptDef` so that an AI subprogram receives a list of available tools. The user provides tool descriptions at the `makeServiceLib` call site — one per constructor of a request type, with compile-time validation that constructors belong to their declared type. TH generates an enum, `toolInfo`, `ToolCall`/`ToolResponse` sum types, `FromJSON`, `executeToolCall`, and smart constructors. The performer threads `[ToolDescription]` into `runAI` via `HasToolDescriptions` in the environment.

**Completion criterion:** A call to `makeServiceLib "AllServices" [(''MathReq, ''MathResp, [('AddNumbers, "add_numbers", "Add two numbers")])]` compiles, validates `'AddNumbers` is a constructor of `MathReq`, generates `data AllServicesTool = AddNumbers`, `toolInfo AddNumbers = ToolDescription "add_numbers" "..."`, `FromJSON AllServicesToolCall`. A call to `evalScript $ aiScriptWith [AddNumbers] myAIScript` compiles. The existing `aiScript` passes `[]` (no tools).

---

## Assumptions

- `reify ''MathReq` reliably returns constructor list for validation — standard TH operation
- Constructor names are unique within a single ServiceLib — TH checks and errors on duplicates
- `FromJSON req` instance is compatible with the `arguments` field format in tool call JSON — consumer responsibility
- Tool descriptions are literal strings embedded by TH as `LitE (StringL ...)`

## Open Questions (Resolved)

1. JSON tool call format `{"tool_name": ..., "arguments": ...}` — internal format, OpenAI adapter is future work. **Resolved: OK.**
2. Partial constructor coverage — not all constructors must be tools. **Resolved: OK, partial coverage is fine.**

---

## Design

### TH Call (single source of truth)

```haskell
makeServiceLib "AllServices"
    [ (''MathReq, ''MathResp,
        [ ('AddNumbers,      "add_numbers",      "Add two numbers together")
        , ('MultiplyNumbers, "multiply_numbers",  "Multiply two numbers")
        ])
    , (''ExprReq, ''ExprResp,
        [ ('Evaluate, "evaluate_expression", "Parse and evaluate an expression")
        ])
    ]
```

Signature:

```haskell
makeServiceLib :: String -> [(Name, Name, [(Name, String, String)])] -> Q [Dec]
```

### Compile-time Validation

```
TH: reify ''MathReq -> TyConI (DataD ... [ConT 'AddNumbers ..., ConT 'MultiplyNumbers ...])
TH: for each ('AddNumbers, ...) in tool specs -- check 'AddNumbers in constructors of MathReq
TH: if not found -> fail "Constructor 'X is not a constructor of type Y"
```

### TH-generated Entities

For `makeServiceLib "AllServices" [(''MathReq, ''MathResp, [('AddNumbers, "add_numbers", "Add..."), ('MultiplyNumbers, "multiply_numbers", "Mult...")])]`:

```haskell
-- 1. Enum
data AllServicesTool
    = AddNumbers
    | MultiplyNumbers
    deriving (Show, Read, Eq, Ord, Enum, Bounded)

-- 2. Descriptions tied to enum
toolInfo :: AllServicesTool -> ToolDescription
toolInfo AddNumbers      = ToolDescription "add_numbers"      "Add two numbers together"
toolInfo MultiplyNumbers = ToolDescription "multiply_numbers"  "Multiply two numbers"

-- 3. All descriptions
allToolDescriptions :: [ToolDescription]
allToolDescriptions = map toolInfo [minBound .. maxBound]

-- 4. ToolCall / ToolResponse
data AllServicesToolCall
    = MathReqToolCall Text MathReq
    deriving (Show, Eq)

data AllServicesToolResponse
    = MathRespToolResponse MathResp
    deriving (Show, Eq)

-- 5. FromJSON (tool names hardcoded from specs)
instance FromJSON AllServicesToolCall where
    parseJSON = withObject "AllServicesToolCall" $ \o -> do
        name <- o .: "tool_name"
        args <- o .: "arguments"
        case name of
            "add_numbers"      -> MathReqToolCall "add_numbers"      <$> parseJSON args
            "multiply_numbers" -> MathReqToolCall "multiply_numbers" <$> parseJSON args
            _ -> fail $ "Unknown tool: " <> toString name

-- 6. Dispatch
executeToolCall :: MonadUnliftIO m => AllServices -> AllServicesToolCall -> m AllServicesToolResponse
executeToolCall sl = \case
    MathReqToolCall _ req -> MathRespToolResponse <$> callService (mathReqService sl) req

toolCallName :: AllServicesToolCall -> Text
toolCallName (MathReqToolCall name _) = name

encodeToolResponse :: Text -> AllServicesToolResponse -> Value
encodeToolResponse name = \case
    MathRespToolResponse resp -> object ["tool_name" .= name, "result" .= toJSON resp]

-- 7. Smart constructors
aiScriptWithAll :: AIScript b -> Script b
aiScriptWithAll = AIScriptDef allToolDescriptions

aiScriptWith :: [AllServicesTool] -> AIScript b -> Script b
aiScriptWith tools = AIScriptDef (map toolInfo tools)
```

### Script Change

```haskell
data Script b where
    TelegramScriptDef :: Text -> TelegramScript b -> Script b
    MailScriptDef :: MailScript b -> Script b
    AIScriptDef :: [ToolDescription] -> AIScript b -> Script b
    DBScriptDef :: PgDB db -> DbMode -> DBScript db b -> Script b
```

### Library Smart Constructor

```haskell
-- LazyCircus.hs
aiScript :: AIScript b -> Script b
aiScript = AIScriptDef []
```

### Environment Threading

```haskell
-- App.Service
class HasToolDescriptions env where
    toolDescriptionsL :: Lens' env [ToolDescription]

-- DefaultApp gets appToolDescriptions :: [ToolDescription] field
-- runAI gains HasToolDescriptions env constraint
-- evalScriptDefault: local (toolDescriptionsL .~ descs) $ runAI scr
```

### Affected Modules

| Layer | Module | Change |
|-------|--------|--------|
| Service | `App.Service` | + `ToolDescription`, `HasToolDescriptions` |
| Service | `App.Service.TH` | Extended `makeServiceLib` with tool specs, validation, enum generation + full tool infrastructure |
| Script | `Script` | `AIScriptDef :: [ToolDescription] -> AIScript b -> Script b` |
| Public API | `LazyCircus` | `aiScript = AIScriptDef []` |
| AI | `Scene.AI.Class` | `runAI` + `HasToolDescriptions` constraint |
| Performer | `Performer.Default` | Thread descriptions through `local` |
| Test | `Testing.Performer` | Mirror dispatch + env instance |
| App | `App.Default` | + field, `HasToolDescriptions` instance |

---

## Alternatives

| Approach | Pros | Cons | Verdict |
|----------|------|------|---------|
| **A: Descriptions in TH call + reify validation** | Single source of truth; compile-time constructor validation; no typeclass boilerplate | Descriptions at TH call site, not near type definition | Chosen |
| **B: `HasToolDescription` + `reifyInstances`** | Descriptions near types | `reifyInstances` doesn't return function bodies | Impossible |
| **C: `ToolConfig = AllTools | OnlyTools (Set Text)`** | Universal | Stringly-typed; no enum; no description binding | Rejected |

---

## Tasks

### T1: Define `ToolDescription` and `HasToolDescriptions`

- **Description:** Add `ToolDescription` data type and `HasToolDescriptions` env class to `App.Service`.
- **Files:** `src/LazyCircus/App/Service.hs`
- **Changes:**
  - Export `ToolDescription(..)`, `HasToolDescriptions(..)`
  - Define:
    ```haskell
    data ToolDescription = ToolDescription
        { toolDescName        :: Text
        , toolDescDescription :: Text
        } deriving (Show, Eq)

    class HasToolDescriptions env where
        toolDescriptionsL :: Lens' env [ToolDescription]
    ```
- **Pitfalls:**
  - `ToolDescription` must be exported for TH-generated code and Script
- **Completion:** Module compiles and exports both
- **Dependencies:** none
- **Complexity / Risk / Value:** Low / green / red

### T2a: TH — constructor validation + enum + `toolInfo` + `allToolDescriptions`

- **Description:** Extend `makeServiceLib` to accept tool specs. Validate constructor names via `reify`. Generate enum, `toolInfo`, `allToolDescriptions`.
- **Files:** `src/LazyCircus/App/Service/TH.hs`
- **Changes:**
  - Change signature to `makeServiceLib :: String -> [(Name, Name, [(Name, String, String)])] -> Q [Dec]`
  - New `validateConstructors :: Name -> [Name] -> Q ()` — `reify reqName`, check each constructor name
  - New `genToolEnumType :: ... -> Q Dec` — `data {Lib}Tool = Con1 | Con2 | ... deriving (Show, Read, Eq, Ord, Enum, Bounded)`
  - New `genToolInfo :: ... -> Q Dec` — `toolInfo Con1 = ToolDescription "name" "desc"`
  - New `genAllToolDescriptions :: ... -> Q Dec` — `allToolDescriptions = map toolInfo [minBound .. maxBound]`
  - Update `makeServiceLib` to call validation and generation
- **Pitfalls:**
  - `reify` returns `TyConI (DataD ...)` or `TyConI (NewtypeD ...)` — handle both
  - Duplicate enum constructor names across request types — detect and fail
  - Constructor order in enum must match `toolInfo` for `[minBound ..]` correctness
  - `deriving Enum, Bounded` requires nullary constructors — satisfied by design
- **Completion:** `makeServiceLib "SL" [(''Req, ''Resp, [('Con, "name", "desc")])]` generates enum + toolInfo + allToolDescriptions; invalid constructor -> compile error
- **Dependencies:** T1
- **Worktree:** wt-1
- **Complexity / Risk / Value:** High / red / red

### T2b: TH — `ToolCall`/`ToolResponse`, `FromJSON`, `executeToolCall`, `toolCallName`, `encodeToolResponse`, smart constructors, constraints

- **Description:** Generate sum types, JSON instances, dispatch function, utilities, smart constructors, and add `FromJSON req`/`ToJSON resp` constraints.
- **Files:** `src/LazyCircus/App/Service/TH.hs`
- **Changes:**
  - `data {Lib}ToolCall = {Type}ToolCall Text {ReqType}` and `data {Lib}ToolResponse = {Type}ToolResponse {ResType}`
  - `FromJSON {Lib}ToolCall` with hardcoded tool name matching from specs
  - `executeToolCall :: MonadUnliftIO m => {Lib} -> {Lib}ToolCall -> m {Lib}ToolResponse`
  - `toolCallName :: {Lib}ToolCall -> Text`
  - `encodeToolResponse :: Text -> {Lib}ToolResponse -> Value`
  - `aiScriptWithAll :: AIScript b -> Script b` and `aiScriptWith :: [{Lib}Tool] -> AIScript b -> Script b`
  - Add `FromJSON (ConT reqName)`, `ToJSON (ConT resName)` to `mk*` constraints
- **Pitfalls:**
  - `FromJSON req` format compatibility with tool arguments — consumer responsibility, document
  - Tool name to request type mapping — available from specs structure
  - New constraints in `mk*` — breaking change, document
- **Completion:** ToolCall decode/encode/execute works; smart constructors compile; constraints enforced
- **Dependencies:** T1, T2a
- **Worktree:** wt-1
- **Complexity / Risk / Value:** High / red / red

### T3: Extend `Script` — `AIScriptDef` gets `[ToolDescription]`

- **Description:** Change `AIScriptDef` constructor to carry tool descriptions.
- **Files:** `src/LazyCircus/Script.hs`
- **Changes:**
  - `import LazyCircus.App.Service (ToolDescription)`
  - `AIScriptDef :: [ToolDescription] -> AIScript b -> Script b`
- **Pitfalls:**
  - Breaking change — all pattern matches must be updated (T6, T7)
- **Completion:** `AIScriptDef` has type `[ToolDescription] -> AIScript b -> Script b`
- **Dependencies:** T1
- **Worktree:** wt-2
- **Complexity / Risk / Value:** Low / green / red

### T4: Update `aiScript` — backward compatible

- **Description:** `aiScript = AIScriptDef []`. Remove `aiScriptWithTools` from library.
- **Files:** `src/LazyCircus.hs`
- **Changes:**
  - `aiScript = AIScriptDef []`
  - Remove `aiScriptWithTools`, `ToolConfig` from exports
  - Update Haddock
- **Completion:** `aiScript body` compiles and equals `AIScriptDef [] body`
- **Dependencies:** T1, T3
- **Worktree:** wt-2
- **Complexity / Risk / Value:** Low / green / red

### T5: Add `HasToolDescriptions` to `DefaultApp`, update `runAI`

- **Description:** Add field to `DefaultApp`, instance, and constraint on `runAI`.
- **Files:** `src/LazyCircus/App/Default.hs`, `src/LazyCircus/Scene/AI/Class.hs`
- **Changes:**
  - `appToolDescriptions :: [ToolDescription]` field in `DefaultApp`
  - `appToolDescriptions = []` in `newDefaultApp`
  - `HasToolDescriptions (DefaultApp serviceLib)` instance
  - `HasToolDescriptions env` constraint on `runAI`
- **Pitfalls:**
  - Don't forget `appToolDescriptions = []` in `newDefaultApp`
- **Completion:** Field and instance exist; `runAI` compiles with new constraint
- **Dependencies:** T1
- **Worktree:** wt-3
- **Complexity / Risk / Value:** Medium / yellow / red

### T6: Update performer dispatch

- **Description:** `evalScriptDefault` threads descriptions via `local`.
- **Files:** `src/LazyCircus/Performer/Default.hs`
- **Changes:**
  - `evalScriptDefault (AIScriptDef descs scr) = local (toolDescriptionsL .~ descs) $ runAI scr`
- **Completion:** Compiles; descriptions available through env
- **Dependencies:** T1, T3, T5
- **Complexity / Risk / Value:** Low / green / red

### T7: Update test performer

- **Description:** Mirror: `HasToolDescriptions` instance for `EnvWithMocks`, update `runScript`.
- **Files:** `src/LazyCircus/Testing/Performer.hs`
- **Changes:**
  - `HasToolDescriptions (EnvWithMocks serviceLib)` instance delegating to `defaultApp`
  - `runScript (AIScriptDef descs scr) = local (toolDescriptionsL .~ descs) $ runAI scr`
- **Completion:** Instance exists; `runScript` compiles; existing tests pass
- **Dependencies:** T3, T5, T6
- **Complexity / Risk / Value:** Medium / green / red

### T8: Documentation, hpack, build

- **Description:** Haddock on all new entities. Document TH API. `hpack && stack build && stack test`.
- **Files:** All touched files
- **Completion:** `hpack && stack build && stack test` passes; all new entities have Haddock
- **Dependencies:** T1-T7
- **Complexity / Risk / Value:** Medium / yellow / yellow

---

## Execution Plan

Critical path: `T1 -> T2a -> T2b -> T6 -> T7 -> T8`

Parallel groups:
- wt-1: T2a -> T2b (TH)
- wt-2: T3 -> T4 (Script + LazyCircus)
- wt-3: T5 (App.Default + AI.Class)
- Main: T6 -> T7 -> T8

Start with T2a (highest risk: reify + validation + enum generation).
