# Lazy Circus Reference: Logging Principles

Read this when:

- deciding where to place log calls in a new scenario or scene script
- reviewing whether existing logs follow the right conventions
- choosing between `logInfo` / `logWarn` / `logError` / `logSensitive`
- deciding whether to put data into log text or into logging context
- understanding the debug vs prod visibility model

For the syntax of logging APIs (which function to call, in which layer), see
[reference/scenarios.md](scenarios.md) for scenario-level and
[reference/effects.md](effects.md) for scene-level.

## Two-Layer Model

Scenario owns the narrative. Scene records facts.

| Layer | Knows | Logs | API |
|---|---|---|---|
| Scenario (`ScenarioProgram`) | business context (userId, actId, what we decided) | decisions, branch points, entry/exit | `logInfo`, `logWarn`, `logError`, `logSensitive` |
| Scene (DB/Telegram/AI/Mail/HTTP scripts) | one domain operation | facts inside that domain | `slogInfo`, `slogWarn`, `slogError`, `slogSensitive` |

Scenario is the primary storyteller. Scene-layer logs are secondary detail.

## Six Principles

### 1. Scenario tells the story, Scene records facts

Scenario logs explain what happened at the orchestration level:

```haskell
myScenario = do
    logInfo "Creating act"
    mAct <- evalScript $ DBScriptDef simpleDb ReadWrite $ create row
    case mAct of
        Nothing -> logError "DB create returned no rows"
        Just act -> do
            logInfo $ "Created act with id: " <> tshow (circusActId act)
```

Scene logs record individual steps inside a DSL:

```haskell
dbStep :: DBScript SimpleDb ()
dbStep = do
    slogInfo "Inside transaction"
    _ <- findAll (CircusActId 42)
    pure ()
```

### 2. Automatic timing is not manual

`timedAndLog` wraps every performer IO operation automatically, adding `lang`, `op`, and
`elapsed_ms` to logging context. Do not measure timing by hand:

```haskell
-- WRONG: manual timing
slogInfo "Starting DB query"
result <- findAll key
slogInfo "Finished DB query"

-- RIGHT: timedAndLog in the performer already handles this;
-- just log the business fact if needed
result <- findAll key
```

If you need to time a custom block inside a scene script, use `swithLogCtx` to label it and
let the performer's `timedAndLog` handle the actual measurement at the boundary.

### 3. Context goes in `withLogContext`, not in the message string

Structured key-value context propagates through all nested logs (both scenario and scene).

```haskell
-- WRONG: data baked into string
logInfo $ "Processing query: " <> userQuery

-- RIGHT: data in structured context
withLogContext [("query", userQuery)] $ do
    logInfo "Processing query"
```

```haskell
-- RIGHT: multiple context entries
withLogEntry "act_id" actId $ do
    withLogContext [("stage", "validation")] $ do
        logInfo "Validating act"
```

This keeps user data out of log text and enables filtering by context keys.

### 4. Log WHAT happened and WHAT decision was made. Not WHY.

The "why" lives in the code. The log captures the observable outcome.

```haskell
-- WRONG: restates reasoning that is visible in code
logWarn "Agent returned no response because the AI model returned empty output after retries"

-- RIGHT: states the decision
logWarn "Agent: no response"
```

Agents (70% of log readers) go to the code for "why". Humans (30%) can too.

### 5. Debug vs Prod is controlled by message type, not by log level

Lazy Circus uses two visibility modes:

| Mode | Visible |
|---|---|
| **Production** | `AppLogMsg` (info), `WarnLogMsg`, `ErrorLogMsg` + automatic timings |
| **Debug** | everything above + `SensitiveLogMsg` (maps to `LevelDebug`, source `"AppSecret"`) |

Use `logSensitive` / `slogSensitive` for content that should only appear in debug: SQL strings
(without parameters), prompt descriptions, internal routing details.

```haskell
logInfo "Running agent query"           -- visible in prod
logSensitive "Agent prompt template"    -- debug only
```

There is no need for five severity levels (trace/debug/info/warn/error). Two modes are enough.

### 6. Never log user data — discipline, not redaction

There is no automatic redaction mechanism. The contract is: do not put user data into log text.

```haskell
-- WRONG: user content in log
logInfo $ "User asked: " <> userMessage

-- RIGHT: only the ID, in structured context
withLogEntry "message_id" msgId $ do
    logInfo "Processing user message"
```

User data includes: LLM response bodies, PDF bytes, email bodies, Telegram message text,
file contents. Log metadata and IDs instead.

For rare cases where you must reference something sensitive, use `logSensitive` so it stays
in debug mode only.

## Placement Checklist

When writing or reviewing logging, check each situation:

| Situation | Action |
|---|---|
| Scenario entry point | `logInfo` with scenario name |
| Scenario exit point | `logInfo` with outcome |
| Branch / decision in scenario | `logInfo` or `logWarn` with the decision taken |
| Error or anomaly | `logWarn` or `logError` |
| External call (DB, HTTP, TG, AI, Mail) | No manual log needed — `timedAndLog` in performer handles it |
| Need traceability context | `withLogContext` / `withLogEntry` with key-value pairs |
| Debug-only detail (SQL, prompt desc) | `logSensitive` / `slogSensitive` |
| Fact inside a scene script | `slogInfo` |
| User data (message text, LLM output, file content) | **Never log** — use ID in `withLogEntry` instead |
| Timing measurement | **Never manual** — `timedAndLog` handles it |

## Anti-Patterns

### Logging user data in message text

```haskell
-- WRONG
logInfo $ "AI responded: " <> aiResponse
logInfo $ "User email: " <> email

-- RIGHT
withLogEntry "response_id" respId $
    logInfo "AI response received"
```

### Manual start/finish timing

```haskell
-- WRONG
slogInfo "Query started"
result <- findAll key
slogInfo "Query finished"

-- RIGHT: just do the operation; timedAndLog in performer emits timing
result <- findAll key
```

### Using the wrong layer API

```haskell
-- WRONG: scenario API inside scene script
dbStep = do
    logInfo "In DB step"       -- logInfo is for ScenarioProgram

-- WRONG: scene API inside scenario
myScenario = do
    slogInfo "Starting"        -- slogInfo is for scene scripts

-- RIGHT
dbStep = slogInfo "In DB step"
myScenario = logInfo "Starting"
```

### Explaining reasoning in log text

```haskell
-- WRONG
logWarn "Skipping notification because the user has disabled Telegram alerts in their profile settings"

-- RIGHT: the "why" is in the code
logWarn "Notification skipped"
```

### Wrapping every operation in `runSafely` just to log errors

```haskell
-- WRONG: swallows errors into Either without meaningful handling
result <- runSafely $ evalScript $ aiScript $ ask req
case result of
    Left _ -> logError "Failed"    -- lost context
    Right a -> pure a

-- RIGHT: let the error propagate, or handle it with context
result <- runSafely $ evalScript $ aiScript $ ask req
case result of
    Left err -> logWarn $ "AI call failed: " <> tshow err
    Right a -> pure a
```
