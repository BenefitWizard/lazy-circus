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