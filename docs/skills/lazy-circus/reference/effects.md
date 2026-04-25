# Lazy Circus Reference: Effect Languages

Read this when:

- using or reviewing `DBScript`, `TelegramScript`, `AIScript`, or `MailScript`
- checking scene-level logging APIs
- deciding whether to use `tgScript`, `mailScript`, `aiScript`, or `DBScriptDef`

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

Main operation:

| Function | Result |
|---|---|
| `ask` | `Maybe a` where `a` has `FromJSON` |

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
    }
```

Production AI behavior:

- uses OpenAI-compatible client methods from the environment
- hardcodes the chat model to `deepseek-chat`
- requests JSON object output
- decodes the first choice only
- logs decode failures as a sensitive log message with the current logging context
- returns `Nothing` when decoding fails or content is absent

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

## Logging Inside Scene Languages

Module: `LazyCircus.Scene.Log`

Use these inside DB, Telegram, AI, and Mail scripts:

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