# Lazy Circus 

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![GHC: 9.12](https://img.shields.io/badge/GHC-9.12-blueviolet.svg)](https://www.haskell.org/ghc/)

> **Why the name "Lazy Circus"?**
> Managing multiple side effects in Haskell (databases, external APIs, logging, async execution) can often feel like a chaotic juggling act—a veritable "circus" of monad transformers and complex type constraints. 

## Motivation

The typical workflow of an API service is straightforward:
1. Accept a request
2. Execute business logic
3. Return a response

Libraries like `servant` handle steps 1 and 3 perfectly. However, the core value of your application undeniably lives in step 2. A robust business logic layer needs to handle multiple concerns: state computations, database transactions, 3rd-party API integrations, structured logging, and graceful error recovery.

Balancing these concerns often leads to messy codebases. As developers, we actually want:
* **A simple mental model** to reason about the program easily.
* **Safe, error-resistant abstractions** where making the right choice is easier than making the wrong one.
* **Painless testability** to verify complex logic without spinning up real infrastructure.
* **Solid performance** to minimize infrastructure costs.

**Lazy Circus** was built to enforce exactly these guarantees:

* **Domain-Driven Effect Isolation:** Effects are grouped into standalone DSLs (Domain Languages). When you write database logic, you don't have to worry about accidentally triggering an HTTP request.
* **Regulated Interactions:** The interaction between different effect languages is strictly regulated. For instance, the type system prevents you from making a long-running external API call in the middle of a database transaction.
* **Out-of-the-box Testability:** Everything is easily testable using mock interpreters (`Performers`). You can run your production business scenarios using a test environment, inspect the exact sequence of triggered effects, and assert behavior without real side-effects.
* **Proven Performance:** Built for real-world workloads. The application this library was originally developed for (a Telegram bot with heavy DB and API manipulations) comfortably handles ~4500 RPS in a Docker container (1 CPU, 512MB RAM) on a standard 2021 laptop.

*Historical note: Lazy Circus was created in early 2025. It was originally developed as the foundation for a real-world production application and later open-sourced as a standalone library. Its design is heavily inspired by Alexander Granin's book [Functional Design and Architecture](https://www.manning.com/books/functional-design-and-architecture).*

## Batteries Included

Lazy Circus ships with a rich set of built-in capabilities ready for production use:

* **Orchestration Framework:** A robust control layer (`ScenarioProgram`) for executing sub-scenarios, spawning asynchronous background tasks, managing environment state, handling errors gracefully, and calling registered services. You can orchestrate the built-in effects or plug in your own.
* **Database Effect DSL (via `beam`):** A comprehensive database language supporting both typed CRUD operations and raw queries. Advanced features like separate Read-Only connections, Row-Level Security (RLS), and transaction management are supported out-of-the-box.
* **Telegram Bot Integration:** A ready-to-use effect for sending messages and reactions. It natively supports running multiple bots from a single application seamlessly.
* **Mail Integration:** A robust email effect for composing and sending transactional emails.
* **AI Provider Integration (DeepSeek):** AI effect DSL tailored for interacting with LLM providers like DeepSeek. It features out-of-the-box support for strict structured responses and implements an XML-like prompt templating language which significantly improves prompt adherence.
* **Production & Test Interpreters:** Two distinct performers (`DefaultPerformer` and `TestInterpreter`). The test runtime keeps the same shared-runner architecture as production, but swaps capabilities at the edges: DB can stay real, while Telegram, mail, AI, logging, and async work are captured through mocks in the capability layer.
* **Structured Async Logging:** High-performance, asynchronous structured logging available universally across all effect types. It supports nested log contexts (e.g., automatically attaching a `user_id` or `trace_id` to all subsequent nested calls).
* **Service Call Infrastructure:** A transparent mechanism for running parallel typed workers with a standardized request/response interface. When the application needs concurrent background workers that process requests one at a time, register them through `LazyCircus.App.Service` and call from scenarios with `callService` — no coupling to concrete implementations. The `makeServiceLib` Template Haskell macro generates the service library data type, config, dispatch instances, builder function, and optional tool-call plumbing for AI integration from a list of request/response/tool-spec triples.
* **AI Coding Agent Skill:** A pre-configured custom AI skill instruction set located in `docs/skills/lazy-circus/` to teach GitHub Copilot (or other AI assistants) the architectural patterns and conventions of Lazy Circus.

## Using the AI Assistant Skill

Lazy Circus strongly relies on domain-driven structures (Church-encoded free monads) that generic AI models might struggle to write perfectly on the first try. To solve this, we ship a custom **Skill** specifically designed for automated coding agents. With this skill applied, AI models at the level of GML-4.7 can successfully and accurately write business logic and tests using the framework.

When installed, the skill provides your AI assistant (e.g., GitHub Copilot) with deep context about:
* How to write and use effects via `Script` and `ScenarioProgram`
* Appropriate usage of DB, Telegram, and Logging DSLs
* How to write tests with `TestInterpreter` and assert side-effects
* Haskell formatting and documentation rules used in the project

### Installation Instructions

To install the Lazy Circus skill for your AI workspace:

Copy the `docs/skills/lazy-circus` folder into your project's AI skills directory (for example, `.claude/skills/lazy-circus` or a custom AI prompts folder).

## Installation

Since `lazy-circus` is not yet available on Hackage, you need to install it directly from GitHub.

**Using Cabal (`cabal.project` & `package.yaml`):**

First, add the repository to your `cabal.project` file:
```cabal
source-repository-package
  type: git
  location: https://github.com/BenefitWizard/lazy-circus.git
  tag: <commit-hash>
```

Then, add it to your `dependencies` in `package.yaml` (or `build-depends` directly in `.cabal`):
```yaml
dependencies:
  - lazy-circus
```

**Using Stack (`stack.yaml`):**

Add the library to your `extra-deps` with the repository and commit:
```yaml
extra-deps:
  - github: "BenefitWizard/lazy-circus"
    commit: "<commit-hash>"
```

## Table of Contents

* [Overview](#overview)
* [1. Effect Languages (Scene DSL)](#1-effect-languages-scene-dsl)
* [2. Script — Effect Coproduct](#2-script--effect-coproduct)
* [3. ScenarioProgram — Orchestration Layer](#3-scenarioprogram--orchestration-layer)
* [4. Performer — Interpreters](#4-performer--interpreters)
* [5. DefaultPerformer — Production Runner](#5-defaultperformer--production-runner)
* [6. DB: Adding a New Table](#6-db-adding-a-new-table)
* [7. Testing](#7-testing)
* [8. Adding a New Effect](#8-adding-a-new-effect)
* [9. Key Patterns](#9-key-patterns)
* [10. Included Examples](#10-included-examples)
* [11. Build and Tests](#11-build-and-tests)

## Overview

Lazy Circus is an effect framework for Haskell built on **Church-encoded free monads** (`Control.Monad.Free.Church.F`). Business logic is written using declarative Effect DSLs, completely decoupled from specific implementations (IO, mocks, etc.).

### Architecture (layers from bottom up)

```
┌──────────────────────────────────────────────────────┐
│  ScenarioProgram s sl a                              │  Orchestration Layer
│  (logging, errors, time, async, context, services)   │
├──────────────────────────────────────────────────────┤
│  Script a                                            │  Coproduct (sum of effects)
│  TelegramScript | MailScript | AIScript | DBScript   │
├──────────────────────────────────────────────────────┤
│  Scene-DSL  (DBLangF, TelegramScriptF, ...)          │  Effect Functors (GADT)
│  + built-in LogLangF for logging                     │
├──────────────────────────────────────────────────────┤
│  Performer  (typeclass-interpreters)                 │  Execution Layer
│  runDB, runTelegram, runAI, runMail                  │
│  + DefaultPerformer for production                   │
└──────────────────────────────────────────────────────┘
```

---

## 1. Effect Languages (Scene DSL)

Each effect is described as a GADT functor. Church-encoding (`F`) transforms it into a monadic program.

### Available Languages

| Language | Program Type | Module |
|----------|--------------|--------|
| Database | `DBScript db a` | `LazyCircus.Scene.DB` |
| Telegram | `TelegramScript a` | `LazyCircus.Scene.Telegram` |
| AI | `AIScript a` | `LazyCircus.Scene.AI` |
| Mail | `MailScript a` | `LazyCircus.Scene.Mail` |
| Logging | built into all languages | `LazyCircus.Scene.Log` |

### Example: DB Script

```haskell
import LazyCircus.Scene.DB

-- Create a record
createAct :: CircusActT Maybe -> DBScript SimpleDb (Maybe CircusAct)
createAct act = create act

-- Find by ID
findAct :: Int32 -> DBScript SimpleDb (Maybe CircusAct)
findAct actId = find (CircusActId actId)

-- Update
updateDesc :: Text -> Int32 -> DBScript SimpleDb [CircusAct]
updateDesc newDesc actId = update patch (CircusActId actId)
  where patch = CircusAct Nothing Nothing Nothing (Just newDesc) Nothing

-- Delete
deleteAct :: Int32 -> DBScript SimpleDb ()
deleteAct actId = delete (CircusActId actId)

-- Transaction
transactionalAct :: DBScript SimpleDb ()
transactionalAct = withTransaction $ do
    mAct <- createAct myAct
    _ <- forM mAct $ \act -> updateDesc "New desc" (circusActId act)
    pure ()
```

### Example: Telegram Script

```haskell
import LazyCircus.Scene.Telegram

greetUser :: SendMessageRequest -> TelegramScript (Response Message)
greetUser request = do
    response <- sendMessage request
    slogInfo "Message sent"
    pure response
```

### Example: Mail Script

```haskell
import LazyCircus.Scene.Mail

notifyUser :: Address -> Text -> Text -> MailScript ()
notifyUser to subject body = do
    mail <- makeMail to subject body
    sendMail mail
```

### Example: AI Script

```haskell
import LazyCircus.Scene.AI

getAnswer :: AIRequest MyResponse -> AIScript (Maybe MyResponse)
getAnswer request = ask request
```

### Logging inside any script

All Scene languages have built-in logging via `HasLogLang`:

```haskell
slogInfo "Informational message"    -- level: Info
slogWarn "Warning message"          -- level: Warn
slogError "Error message"           -- level: Error
slogSensitive "Debug-only message"  -- level: Debug (secret)

-- Logging context (key-value, nested)
swithLogCtx [("user_id", "42")] $ do
    slogInfo "This message includes user_id in context"
```

---

## 2. Script — Effect Coproduct

`Script` is a GADT that wraps any sub-language into a single type. Using smart constructors:

```haskell
import LazyCircus (tgScript, mailScript, aiScript)

-- Wrap sub-languages
tgScript "my-bot-name"   myTelegramScript  :: Script b
mailScript               myMailScript      :: Script b
aiScript                 myAIScript        :: Script b
```

`aiScript` wraps with an empty tool-description list. For tool-aware AI scripts, use `AIScriptDef` directly or the TH-generated `aiScriptWithAll` / `aiScriptWith` smart constructors (see [Section 8](#8-adding-a-new-effect)).

For DB scripts, use the `DBScriptDef` constructor directly:

```haskell
DBScriptDef myDb ReadWrite myDbScript :: Script b
```

---

## 3. ScenarioProgram — Orchestration Layer

`ScenarioProgram s sl a` is the main type for writing business scenarios. It adds:

- `evalScript` — execute a nested `Script`
- `throw` / `runSafely` — error handling
- `getDateTime` — get current time
- `log` / `logInfo`, `logWarn`, `logError`, `logSensitive` — scenario-level logging
- `withLogContext`, `withLogEntry`, `with2LogEntries` — logging context
- `getExtraContext`, `readFromExtraContext`, `getFeatureFlag` — configuration
- `runAsync` — asynchronous execution
- `callService` — call a registered service via the service library

### Example: Full Scenario

```haskell
import LazyCircus.Scenario
import LazyCircus (tgScript, aiScript)
import LazyCircus.App.Service (NoServiceLib)

myScenario :: ScenarioProgram Script NoServiceLib ()
myScenario = do
    logInfo "Starting scenario"

    result <- runSafely $ do
        -- Call AI
        answer <- evalScript $ aiScript $ ask myRequest

        -- Call Telegram
        case answer of
            Just response -> do
                evalScript $ tgScript "bot" $ sendMessage (buildRequest response)
                pure ()
            Nothing ->
                throw $ userError "AI returned nothing"

    case result of
        Left (e :: SomeException) ->
            logError $ "Scenario failed: " <> tshow e
        Right _ ->
            logInfo "Scenario completed"
```

---

## 4. Performer — Interpreters

### How Interpretation Works

Each sub-language has its own typeclass interpreter:

| Typeclass | Runner Method |
|-----------|-------------|
| `DBScriptPerformer m` | `runDB :: PgDB db -> DbMode -> DBScript db a -> m a` |
| `TelegramScriptPerformer m` | `runTelegram :: TelegramScript a -> m a` |
| `AILangPerformer m` | `runAI :: AIScript a -> m a` |
| `MailScriptPerformer m` | `runMail :: MailScript a -> m a` |
| `ScenarioPerformer script serviceLib m` | `run :: ScenarioProgram script serviceLib a -> m a` |

Interpretation occurs via `iterM` — folding the Church-encoded free monad into the target monadic context.

### Logging Mechanism

All sub-languages use a common `handleLogLang` handler, which:
1. Extracts the current `LoggingContext` from the reader environment
2. Adds a language tag (`"DB"`, `"Telegram"`, `"AI"`, `"Mail"`)
3. Extracts the call site
4. Writes to a shared `TQueue`

---

## 5. DefaultPerformer — Production Runner

The `LazyCircus.Performer.Default` module provides a ready-to-use production interpreter:

```haskell
import LazyCircus.Performer.Default

-- Run scenario in production environment via the generic 'run' function
runRIO app $ runDefaultPerformer $ run @Script @serviceLib myScenario
```

### Requirements for `DefaultApp serviceLib` Environment

`DefaultApp serviceLib` contains:
- `Connection` — main PostgreSQL connection
- `Maybe Connection` — optional read-only connection
- `BotEnvs` — `Map Text BotEnv` for Telegram bots
- `Methods` — OpenAI client
- `MailCreds` — SMTP credentials
- `LogQueue` / `LoggingContext` — logging
- `JWTSettings` — authorization
- `ExtraContext` — arbitrary configuration (`HashMap Text Text`)
- `ScheduledActions` — queue of async tasks
- `serviceLib` — in-process service handlers (or `NoServiceLib`)
- `appToolDescriptions` — tool descriptions available to AI interpreters

---

## 6. DB: Adding a New Table

To make a new Beam table work with `DBScript`, you need to implement service instances:

```haskell
import LazyCircus.DB.Service

-- 1. Table must be in the DB schema
instance IsInDb MyDb MyTableT where
    getTargetTable = _myTableEntity

-- 2. For INSERT
instance HasCreateService MyDb MyTableT where
    generateInsert db rows = insert (_myTableEntity db) $
        insertExpressions $ map (\r -> ...) rows

-- 3. For SELECT (defines lookup key type)
instance HasReadService MyDb MyTableT where
    type LId MyTableT = MyTableId  -- injective type family
    generateSelect db lid = lookup_ (_myTableEntity db) lid
    generateFiltration _db lid t = myTableId t ==. val_ (unMyTableId lid)

-- 4. For UPDATE
instance HasUpdateService MyDb MyTableT where
    generateAssigment _db partial t = ...

-- 5. For DELETE (often default implementation is enough)
instance HasDeleteService MyDb MyTableT
```

### DbMode

- `ReadWrite` — all operations allowed
- `ReadOnly` — read-only; write operations throw `DbReadOnlyViolation`

### RLS (Row Level Security)

```haskell
import LazyCircus.Scene.DB

-- Transaction with RLS context
withTransactionRLS (rlsCircusId 42) $ do
    findAll someLookup  -- only sees rows where circus_id = 42
```

---

## 7. Testing

The `LazyCircus.Testing.Performer` module provides a mock interpreter for tests:

### Test Runtime Architecture

Tests reuse the same high-level runner structure as production:

- `ScenarioProgram` is interpreted through the normal scenario machinery
- `Script` dispatch still routes into DB / Telegram / Mail / AI branches
- environment projection still happens through wrapper envs such as `AppWithConnection` and `AppWithBotEnv`

What changes is the capability layer underneath that runner:

- DB typically uses a real PostgreSQL connection
- Telegram uses capture mocks for immediate and scheduled sends
- Mail uses real mail building but mocked send capture
- AI returns mock answers (`Nothing` by default)
- `runAsync` records deferred scenarios instead of executing them
- logging is captured as structured messages with context and call-site metadata

This shared-runner design lets tests validate orchestration behavior very close to production while
still giving precise observability over side effects.

### Running Scenario with Mocks

```haskell
import LazyCircus.Testing.Performer
import LazyCircus.App.Service (NoServiceLib)

myTest :: DefaultApp NoServiceLib -> IO ()
myTest app = do
    (mocks, result) <- runWithDefaultMocks app $ do
        runScenarioProgram myScenario

    -- Check captured Telegram requests
    tgReqs <- readTgRequests mocks
    tgReqs `shouldSatisfy` (not . null)

    -- Check logs
    logs <- readLog mocks
    logs `shouldSatisfy` elem (AppLogMsg "Scenario completed")

    -- Check sent emails
    mails <- readSentMails mocks
    mails `shouldSatisfy` (not . null)

    -- Check async tasks
    asyncs <- readScheduledScenarios mocks
    length asyncs `shouldBe` 1
```

### Telegram Mock Setup

```haskell
-- Simple mock (default response for all sendMessage)
mocks <- makeMocks

-- Custom mock with response queue
tgMock <- createTgMock defaultResponse $ Just [myCustomResponse]
```

### What is Mocked

| Effect | Behavior in Tests |
|--------|-------------------|
| Telegram `sendMessage` | Capture requests, returns canned responses |
| Telegram `scheduleMessages` | Captured in a separate list |
| Missing Telegram bot | Throws `NoBotConfigured` during script dispatch |
| Telegram others | no-op / default |
| Mail `sendMail` | Capture Mail values |
| Mail `makeMail` | Actual creation via SMTP credentials from env |
| AI `ask` | Always returns `Nothing` |
| DB | Real execution against DB (requires test database) |
| Logging | Capture in ref-lists (no production queue writes) |
| `runAsync` | Capture ScenarioProgram without execution |

### Common Assertions

- use `readTgRequests` to inspect immediate Telegram sends
- use `readScheduledTgRequests` to inspect deferred Telegram sends
- use `readScheduledScenarios` to inspect `runAsync` capture
- use `readLogWithContext` when you need to assert `withLogContext`, `lang`, or call-site metadata
- if needed, rerun a captured async scenario in the same test runtime to verify its downstream effects

---

## 8. Adding a New Effect

To add a new sub-language:

### Step 1: Define GADT Functor

```haskell
-- src/LazyCircus/Scene/MyEffect/Lang.hs
module LazyCircus.Scene.MyEffect.Lang where

import Control.Monad.Free.Church (F)
import Control.Monad.Free.Church qualified as CF
import LazyCircus.Scene.Log (HasLogLang (..), LogLangF)

data MyEffectF a where
    DoSomething :: Text -> (Result -> a) -> MyEffectF a
    MyEffectLog :: LogLangF MyEffect b -> (b -> a) -> MyEffectF a

instance Functor MyEffectF where
    fmap f (DoSomething txt next) = DoSomething txt (f . next)
    fmap f (MyEffectLog logOp next) = MyEffectLog logOp (f . next)

instance HasLogLang MyEffectF MyEffect where
    embedLog logOp = MyEffectLog logOp id

doSomething :: Text -> MyEffect Result
doSomething txt = CF.liftF $ DoSomething txt id

type MyEffect = F MyEffectF
```

### Step 2: Define Performer Interface

```haskell
-- src/LazyCircus/Scene/MyEffect/Class.hs
module LazyCircus.Scene.MyEffect.Class where

import Control.Monad.Free.Church (iterM)
import LazyCircus.Scene.MyEffect.Lang
import LazyCircus.Scene.Log (handleLogLang)

class (Monad m) => MyEffectPerformer m where
    doSomething' :: Text -> m Result

runMyEffect :: (MyEffectPerformer m, HasLogQueue env, HasLoggingContext env,
                MonadReader env m, MonadIO m) => MyEffect a -> m a
runMyEffect = iterM go
  where
    go (DoSomething txt next) = do
        result <- doSomething' txt
        next result
    go (MyEffectLog logOp next) = handleLogLang "MyEffect" runMyEffect (fmap next logOp)
```

### Step 3: Add to Script and ScenarioPerformer

```haskell
-- In Script.hs add constructor:
data Script b where
    ...
    MyEffectDef :: MyEffect b -> Script b

-- In Performer.hs update onEvalScript:
onEvalScript (MyEffectDef scr) = runMyEffect scr
```

---

## 9. Key Patterns

### Environment Capabilities

All resources are accessible via lens-based typeclasses:

```haskell
class HasDbConnection env where
    dbConnectionL :: Lens' env Connection

class HasLogQueue env where
    logQueueL :: Lens' env (TQueue AppLogMsgWithContext)

class HasLoggingContext env where
    logContextL :: Lens' env LoggingContext
```

This allows composing environments via wrapper types (`AppWithConnection`, `AppWithBotEnv`).

### Runner Alias

```haskell
type Runner r m = forall a. r a -> m a
```

A rank-2 alias for natural transformations from an effect language to an interpreting monad.

### changeEnv

```haskell
changeEnv :: (outer -> inner) -> DefaultPerformer inner a -> DefaultPerformer outer a
```

Projects a performer onto an outer environment via a projection function.

---

## 10. Included Examples

The repository ships with two ready-to-run executables and a shared internal library that demonstrates real-world usage of every Lazy Circus sub-language.

### `example` — Demo Runner

**Entry point:** `app/example/Example.hs`
**Run:** `./run-example.sh` or `stack run example`

The demo connects to PostgreSQL, runs eight scenarios sequentially, and prints the result of each:

| # | Scenario | What it demonstrates |
|---|----------|---------------------|
| 1 | `dbCrudScenario` | Basic CRUD: `create` → `find` → `update` → `findAll` → `delete` |
| 2 | `dbAdvancedScenario` | `createMany`, `withTransaction`, `rawQuery`, `withTransactionRLS` |
| 3 | `telegramScenario` | `getBotName`, `sendMessage`, `sendImportantMessage`, `scheduleMessage`, `setMessageReaction`, `editMessageText` (skipped if `TG_CHAT_ID` not set) |
| 4 | `mailScenario` | `makeMail` + `sendMail` |
| 5 | `aiScenario` | Typed `AIRequest` with structured JSON decoding (skipped if `AI_API_KEY` not set) |
| 6 | `loggingScenario` | All four log levels, `withLogContext`, `withLogEntry`, sub-language logging via `swithLogCtx` |
| 7 | `orchestrationScenario` | `getDateTime`, `getExtraContext`, `readFromExtraContext`, `getFeatureFlag`, `throw`/`runSafely`, `runAsync` |
| 8 | `fullCircusLifecycleScenario` | End-to-end: DB create in transaction → extra context → logging context → mail → async cleanup → `runSafely` |

### `bot` — Interactive Telegram Bot

**Entry point:** `app/bot/BotMain.hs`
**Run:** `./run-bot.sh` or `stack run bot`
**Requires:** `TG_TOKEN` environment variable

A conversational Telegram bot that manages circus acts. Commands:

| Command | Behaviour |
|---------|-----------|
| `/start` | Shows help message |
| `/newact` | Two-step dialog: name → description → creates act + AI reaction + notification email |
| `/list` | Lists all acts from DB |
| `/act <id>` | Shows act details |
| `/react <id>` | Regenerates AI audience reaction for an act |
| `/delete <id>` | Deletes an act |

The bot uses `BotScenarios` for all business logic, keeping the Telegram layer thin.

### Prerequisites

Both examples need PostgreSQL running at `127.0.0.1:5432` (user `postgres`, password `my_password`). The demo automatically creates/drops the `lazy_circus_test` database. A `docker-compose.yml` is provided for convenience.

```bash
docker compose up -d    # start PostgreSQL
cp .env.example .env    # configure API keys and tokens
```

---

## 11. Build and Tests

```bash
# Update cabal file (required before building)
hpack

# Build project
stack build

# Run tests
stack test
```

DB tests require a running PostgreSQL with user `postgres` (password `my_password`) on `127.0.0.1:5432`. Tests create and drop the `lazy_circus_test` database automatically.
