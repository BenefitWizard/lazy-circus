# Lazy Circus Reference: Effect Languages

Read this when:

- using or reviewing `DBScript`, `TelegramScript`, `AIScript`, `MailScript`, or `HTTPScript`
- checking scene-level logging APIs
- deciding whether to use `tgScript`, `mailScript`, `aiScript`, `httpScript`, or `DBScriptDef`

## Effect Languages

Each effect language lives in `LazyCircus.Scene.<Domain>.Lang` and has:

- a GADT functor
- a Church-encoded free alias
- smart constructors
- a `HasLogLang` instance for embedded logging

## DB

Module: `LazyCircus.Scene.DB.Lang`

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
| `update` / `updateMany` | updated rows |
| `delete` | `()` |
| `runQuery` | Beam query result |
| `rawQuery` | decoded SQL rows |
| `withTransaction` | transactional nested script |
| `withTransactionRLS` | transaction with row-level security context |
| `withQSTransaction` | convenience RLS wrapper |

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

- `create` and `createAsIs` use `listToMaybe`; if the interpreter returns `[]`, they yield `Nothing`
- write operations are blocked in `ReadOnly` mode by `DbReadOnlyViolation`
- `withTransactionRLS` applies `SET LOCAL rls.<key> = ?` inside the transaction
- `withQSTransaction` is a convenience wrapper around `withTransactionRLS (rlsQSId qsId)`

### Row Locking

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

Embedding into a scenario:

```haskell
evalScript $ DBScriptDef simpleDb ReadWrite $ find (CircusActId 42)
```

There is no `dbScript` smart constructor in this project. Use `DBScriptDef` directly.

## Telegram

Module: `LazyCircus.Scene.Telegram.Lang`

Program type:

```haskell
type TelegramScript = F TelegramScriptF
```

Main operations:

| Function | Result |
|---|---|
| `getFile` | `Response File` |
| `getBotName` | `Text` |
| `sendMessage` | `Response Message` |
| `sendDocument` | `Response Message` |
| `sendImportantMessage` | `Response Message` |
| `scheduleMessage` / `scheduleMessages` | `()` |
| `setBotCommands` | `()` |
| `setMessageReaction` | `()` |
| `answerCallbackQuery` | `()` |
| `editMessageText` | `Maybe EditMessageResponse` |

Example:

```haskell
notifyUser :: ChatId -> TelegramScript ()
notifyUser chatId = do
    botName <- getBotName
    slogInfo $ "Sending from bot: " <> botName
    _ <- sendMessage $ defSendMessage (SomeChatId chatId) "Hello"
    pure ()
```

Behavior details from the production interpreter:

- `sendImportantMessage` can schedule the message when Telegram returns HTTP 429
- scheduled messages go into the bot queue
- `editMessageText` returns `Nothing` on client error instead of throwing

Wrap Telegram scripts with `tgScript`:

```haskell
evalScript $ tgScript "demo-bot" $ sendMessage req
```

## AI

Module: `LazyCircus.Scene.AI.Lang`

Program type:

```haskell
type AIScript = F AILangF
```

Main operations:

| Function | Result |
|---|---|
| `ask` | `Maybe a` where `a` has `FromJSON` (stateless) |
| `askContinuing` | `(Maybe a, Conversation)` — threads and returns a transcript |
| `solveWithAgent` | `Maybe a` via a tool-using agent loop (stateless) |
| `solveWithAgentContinuing` | `(Maybe a, Conversation)` — agent loop that threads a transcript |

The stateless variants (`ask`, `solveWithAgent`) inject `emptyConversation` and discard the
resulting transcript. Use the `Continuing` variants when a later operation must see the prior
exchange.

Example:

```haskell
fetchDescription :: AIScript (Maybe AiDescription)
fetchDescription = ask request
```

AI request values use the `AIRequest` type from `LazyCircus.AI`:

```haskell
data AIRequest a = AIRequest
    { prompt :: [POML]
    , systemPrompt :: [POML]
    , outputType :: Proxy a
    , thinkingEnabled :: Bool
    }
```

For tool-using agent loops, use `AgentRequest` (also from `LazyCircus.AI`):

```haskell
data AgentRequest a = AgentRequest
    { agentPrompt :: [POML]
    , agentSystemPrompt :: [POML]
    , agentMaxIterations :: Natural
    , thinkingEnabled :: Bool
    }
```

### Conversation Threading

A `Conversation` (from `LazyCircus.AI.Conversation`, re-exported by `LazyCircus.AI` and
`LazyCircus.Scene.AI`) is a durable transcript of prior turns. Build one with
`emptyConversation` or `conversationFromTurns`, and accumulate it across operations with its
`Semigroup`/`Monoid` instances.

INVARIANT: a `Conversation` never contains a `Chat.System` message — system context is
re-injected from the request's `systemPrompt` on every operation. The `Conversation`
constructor is intentionally not exported; build transcripts only through the smart
constructors.

```haskell
multiTurn :: AIScript (Maybe Answer, Conversation)
multiTurn = do
    (r1, conv) <- askContinuing firstRequest emptyConversation
    askContinuing secondRequest conv
```

Production AI behavior:

- uses OpenAI-compatible client methods from the environment
- hardcodes the chat model to `deepseek-v4-flash`
- `ask` requests JSON object output and decodes the first choice only
- `solveWithAgent` runs a ReAct loop: it sends the transcript, executes any tool calls via the
  registered `ToolCallExec`, appends results, and repeats until the model returns a final answer
  or `agentMaxIterations` is exhausted
- logs decode failures and agent tool calls/results as sensitive log messages with the current
  logging context
- returns `Nothing` when decoding fails, content is absent, or the iteration budget is exhausted

Wrap AI scripts with `aiScript`.

### Tool-Aware AI Scripts

The `AIScriptDef` constructor accepts a list of `ToolDescription` values:

```haskell
AIScriptDef :: [ToolDescription] -> AIScript b -> Script b
```

`aiScript` passes an empty list (`[]`). When services are registered via `makeServiceLib` with tool specs, TH generates:

- `aiScriptWithAll :: AIScript b -> Script b` — passes all registered tool descriptions
- `aiScriptWith :: [LibTool] -> AIScript b -> Script b` — passes a subset

This lets the AI runtime know which tools (services) it can call.

### Prompt Templates (POML)

The `prompt` and `systemPrompt` fields of `AIRequest` / `AgentRequest` are `[POML]` lists. A
`POML` value is a node of the Prompt-Oriented Markup Language AST. There are three ways to
build one, in increasing order of type safety:

| Approach | Module | When to use |
|---|---|---|
| Hand-built AST + smart constructors | `LazyCircus.AI.POML.Types` | small, static, programmatic prompts |
| Pure parse of `.poml` text | `LazyCircus.AI.POML.Parser` (`parsePomlText`) | runtime/test construction from a template string |
| Compile-time TH macro | `LazyCircus.AI.POML.TH` (`makePoml`) | authored `.poml` files with template variables (preferred for real prompts) |

`renderPOMLtoPrompt :: [POML] -> Text` (from `LazyCircus.AI.POML`) flattens any `[POML]` into the
prompt text handed to the model. It is called internally by the AI interpreter; you normally do
not call it yourself.

#### Hand-Built AST

The `POML` constructors group into:

- **Leaf / inline:** `Text`, `Var` (smart: `text`, `var`; `IsString` instance makes string literals coerce to `Text`)
- **Basic block / inline tags:** `Paragraph`, `Heading`, `Code`, `Strong`, `Italic`, `Underline`, `Strikethrough`, `Span`, `Br` (smart: `p_`, `h_`, `hLvl_`, `code_`, `b_`, `i_`, `u_`, `s_`, `span_`, `br`)
- **Semantic prompt blocks:** `CP`, `List`, `Role`, `Task`, `Example`, `ExampleSet`, `ExampleInput`, `ExampleOutput`, `Table` (smart: `cp_`/`cp`, `list_`/`list`, `role_`/`role`, `task_`/`task`, `example_`/`example`, `examples_`/`examples`, `exampleInput_`/`exampleInput`, `exampleOutput_`/`exampleOutput`, `csvTable_`/`csvTable`)

Each semantic block takes a `*Params` record with a `default*Params` base (e.g. `defaultCPParams`, `defaultListParams`). The `_`-suffixed smart constructors use the defaults; the non-suffixed variants take explicit params.

```haskell
import LazyCircus.AI.POML.Types (POML, p_, cp_, text)

myPrompt :: [POML]
myPrompt =
    [ p_ ["Summarize the following:"]
    , cp_ "Input" [text someUserText]
    ]
```

#### Pure Parser

`parsePomlText :: Text -> Either String POML` parses a `.poml` document (XML root `<poml>`,
whitelisted body tags) directly into a `POML` AST in one step. Static text lowers to `Text`; a
bare `{{name}}` placeholder lowers to `Var "name"`. Template concatenations
(`{{a + " " + b}}`) and templated `<cp caption="{{...}}">` cannot be expressed in the AST and
return `Left` — use the TH macro for those.

```haskell
import LazyCircus.AI.POML.Parser (parsePomlText)

parsed :: Either String POML
parsed = parsePomlText "<poml><p>Hello</p></poml>"
```

#### Compile-Time TH Macro

`makePoml :: String -> FilePath -> Q [Dec]` (from `LazyCircus.AI.POML.TH`) reads a `.poml` file at
compile time and generates:

- a record type `{Base}Input` (only when the document has `<let name="…" type="…"/>` declarations), with one typed field per variable (`string` → `Text`, `boolean` → `Bool`, `number` → `Float`, `poml` → `POML`);
- a function `{base} :: {Base}Input -> POML` (or a nullary `{base} :: POML` when there are no `<let>` declarations) whose body constructs a single `POML` node.

The `base` argument drives the generated names; the file is registered with `addDependentFile`
so edits trigger recompilation.

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell    #-}

import LazyCircus.AI.POML (renderPOMLtoPrompt)
import LazyCircus.AI.POML.TH (makePoml)
import LazyCircus.AI.POML.Types (POML (..), defaultListParams)  -- must stay in scope

-- prompts/hello.poml:
--   <poml>
--     <let name="name" type="string"/>
--     <p>Hello, {{name}}!</p>
--   </poml>
$(makePoml "hello" "prompts/hello.poml")
-- generates: data HelloInput = HelloInput { name :: Text }
--             hello :: HelloInput -> POML

greeting :: Text
greeting = renderPOMLtoPrompt [hello HelloInput{ name = "World" }]
```

Concatenations (`{{firstName + " " + lastName}}`) and templated `<cp caption="{{topic}}">` are
only representable through the macro — they are spliced at the AST level inside the generated
function. A `poml`-typed variable may appear as a subtree but cannot participate in a text
concatenation (the splice fails with a clear message).

Consumer requirements for `makePoml`: keep `POML(..)` and the referenced `default*Params` values
in scope, and enable `OverloadedStrings` (already a library default). If two splices in the same
module produce record types that share a field name, also enable `DuplicateRecordFields`.

See `app/example/Example/PomlDemo.hs` and the `app/example/prompts/*.poml` templates
(`hello.poml`, `greeting.poml`, `contact.poml`) for the canonical worked example.

## Mail

Module: `LazyCircus.Scene.Mail.Lang`

Program type:

```haskell
type MailScript = F MailLangF
```

Main operations:

| Function | Result |
|---|---|
| `makeMail` | `Mail` |
| `sendMail` | `()` |

Example:

```haskell
welcomeMail :: Address -> MailScript ()
welcomeMail recipient = do
    mail <- makeMail recipient "Welcome" "Hello from Lazy Circus"
    slogInfo "Mail built"
    sendMail mail
```

Wrap Mail scripts with `mailScript`.

## HTTP

Module: `LazyCircus.Scene.HTTP.Lang`

Program type:

```haskell
type HTTPScript = F HTTPLangF
```

Main operation:

| Function | Result |
|---|---|
| `runClient` | `Either ClientError a` |

`runClient` takes a `ClientM a` action (from servant-client) and lifts it into the HTTP script language. The result is `Either ClientError a` — `Left` for network or decode failures, `Right` for success.

Example:

```haskell
import Servant.Client (ClientM, BaseUrl(..), mkClientEnv)

fetchData :: ClientM MyData -> HTTPScript (Either ClientError MyData)
fetchData request = runClient request
```

Production HTTP behavior:

- uses the shared `httpManager` from `DefaultApp` to create a `ClientEnv`
- dispatches the servant-client action via `runClientM`
- returns `Left ClientError` on connection or decode failures

Wrap HTTP scripts with `httpScript`, passing the target `BaseUrl`:

```haskell
evalScript $ httpScript (BaseUrl Https "api.example.com" 443 "") $ runClient myRequest
```

## Logging Inside Scene Languages

For logging principles (what to log, where to place logs, what not to log), see
[reference/logging.md](logging.md).

Module: `LazyCircus.Scene.Log`

Use these inside DB, Telegram, AI, Mail, and HTTP scripts:

- `slogInfo`
- `slogWarn`
- `slogError`
- `slogSensitive`
- `swithLogCtx`

Example:

```haskell
dbStep :: DBScript SimpleDb ()
dbStep =
    swithLogCtx [("phase", "db-read")] $ do
        slogInfo "About to fetch rows"
        _ <- findAll (CircusActId 42)
        pure ()
```

`handleLogLang` is the shared interpreter helper that:

- reads the current `LoggingContext`
- adds the language tag such as `DB` or `Telegram`
- preserves nested log context
- emits `AppLogMsgWithContext`