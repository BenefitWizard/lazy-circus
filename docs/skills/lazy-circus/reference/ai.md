# Lazy Circus Reference: AI Effect

Read this when:

- using or reviewing `AIScript` (module `LazyCircus.Scene.AI.Lang`)
- building `AIRequest` / `AgentRequest` or overriding sampling via `AIParams`
- threading multi-turn `Conversation`
- exposing services to the model as tools

For prompt templates (`POML`, `.poml` files, `makePoml`), see [poml.md](poml.md).

## Contents

- Operations
- Requests
- Request Parameters (`AIParams`)
- Conversation Threading
- Tool-Aware AI Scripts
- Review Checklist

## Operations

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

Signatures (module `LazyCircus.Scene.AI.Lang`; `m` is any free-monad over `AILangF`, i.e. `AIScript`):

```haskell
ask                       :: (MonadFree AILangF m, FromJSON b) => AIRequest b -> m (Maybe b)
askContinuing             :: (MonadFree AILangF m, FromJSON b) => AIRequest b -> Conversation -> m (Maybe b, Conversation)
solveWithAgent            :: (MonadFree AILangF m, FromJSON b) => AgentRequest b -> m (Maybe b)
solveWithAgentContinuing  :: (MonadFree AILangF m, FromJSON b) => AgentRequest b -> Conversation -> m (Maybe b, Conversation)
```

The stateless variants (`ask`, `solveWithAgent`) inject `emptyConversation` and discard the
resulting transcript. Use the `Continuing` variants when a later operation must see the prior
exchange.

Example:

```haskell
fetchDescription :: AIScript (Maybe AiDescription)
fetchDescription = ask request
```

## Requests

AI request values use the `AIRequest` type from `LazyCircus.AI` (re-exported via
`LazyCircus.Scene.AI`):

```haskell
data AIRequest a = AIRequest
    { prompt :: [POML]           -- user-facing prompt fragments
    , systemPrompt :: [POML]     -- system-level instruction fragments
    , outputType :: Proxy a      -- phantom proxy guiding JSON decode target
    , thinkingEnabled :: Bool    -- enable DeepSeek thinking mode
    , requestParams :: AIParams  -- OpenAI parameters overlay; mempty keeps defaults
    }
```

Build it with `mkAIRequest :: [POML] -> [POML] -> AIRequest a` (arguments:
prompt, system prompt) — the phantom type is inferred at the use site,
`thinkingEnabled` defaults to `False`, and `requestParams` defaults to
`mempty`. Override either via record update.

The `requestParams` / `agentParams` fields are **strict**: raw record construction
that omits them fails to compile. Always use `mkAIRequest` / `mkAgentRequest`, or set
the field explicitly in a record update.

For tool-using agent loops, use `AgentRequest` (also from `LazyCircus.AI`):

```haskell
data AgentRequest a = AgentRequest
    { agentPrompt :: [POML]         -- user-facing prompt fragments
    , agentSystemPrompt :: [POML]   -- system-level instruction fragments
    , agentMaxIterations :: Natural -- maximum ReAct iterations
    , thinkingEnabled :: Bool       -- enable DeepSeek thinking mode
    , agentParams :: AIParams       -- OpenAI parameters overlay; mempty keeps defaults
    }
```

with its smart constructor
`mkAgentRequest :: [POML] -> [POML] -> Natural -> AgentRequest a` (prompt,
system prompt, iteration budget).

## Request Parameters (`AIParams`)

`AIParams` (from `LazyCircus.AI`, re-exported by `LazyCircus.Scene.AI`) is a
right-biased `Semigroup`/`Monoid` overlay for OpenAI chat-completion
parameters. Every field is `Maybe`; `Nothing` keeps the default request
behaviour, `Just` overrides the corresponding request field.

Build single-field fragments with the `with*` smart constructors and combine
them with `<>`:

| Constructor | Overrides |
|---|---|
| `withModel :: Text -> AIParams` | `model` (falls back to `deepseek-v4-flash` when unset) |
| `withTemperature :: Double -> AIParams` | `temperature` |
| `withTopP :: Double -> AIParams` | `top_p` |
| `withMaxCompletionTokens :: Natural -> AIParams` | `max_completion_tokens` |
| `withSeed :: Integer -> AIParams` | `seed` |
| `withFrequencyPenalty :: Double -> AIParams` | `frequency_penalty` |
| `withPresencePenalty :: Double -> AIParams` | `presence_penalty` |
| `withStop :: [Text] -> AIParams` | `stop` sequences (overridden wholesale, never concatenated) |
| `withUser :: Text -> AIParams` | end-user identifier |
| `withReasoningEffort :: ReasoningEffort -> AIParams` | `reasoning_effort` (`ReasoningEffort(..)` is re-exported) |

Semantics:

- `mempty` keeps the default request behaviour (no sampling fields are sent)
- `<>` is right-biased: a set field of the right operand wins, and list fields
  (`aiStop`) are overridden wholesale, never concatenated
  (`withStop ["a"] <> withStop ["b"]` = `Just ["b"]`)
- the overlay applies to `ask` requests and to EVERY agent-loop iteration
- `response_format` and `tools`/`tool_choice` are intentionally not
  overridable (the JSON decode contract depends on the former; tools are
  registered at the scene level via `aiScriptWith` / `aiScriptWithAll`)
- `thinkingEnabled` stays a separate `Bool` (it renders a DeepSeek-specific
  `extra` object), not an `AIParams` field

```haskell
creativeAnswer :: AIScript (Maybe Answer, Conversation)
creativeAnswer =
    askContinuing req emptyConversation
  where
    req = (mkAIRequest [cp_ "Question" ["Tell me a joke"]] jokerSystemPrompt)
        { requestParams = withTemperature 0.9 <> withMaxCompletionTokens 512
        }
```

The same record-update pattern works for agent requests:
`(mkAgentRequest prompt sys 10){ agentParams = withModel "m" <> withTemperature 0.7 }`.

See `docs/ai-request-vs-openai-api.md` for the full mapping between `AIParams`
and the OpenAI `CreateChatCompletion` fields.

## Conversation Threading

A `Conversation` (from `LazyCircus.AI.Conversation`, re-exported by `LazyCircus.AI` and
`LazyCircus.Scene.AI`) is a durable transcript of prior turns. Build one with
`emptyConversation :: Conversation` or
`conversationFromTurns :: Vector Chat.Message -> Conversation`
(where `Chat.Message` is `OpenAI.V1.Chat.Completions.Message (Vector Content)`), and accumulate it
across operations with its `Semigroup`/`Monoid` instances.

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
- defaults the chat model to `deepseek-v4-flash` (`defaultModel`); override per request with `withModel` (`aiModel`)
- applies the request's `AIParams` overlay (`requestParams` / `agentParams`) to every chat-completion request, including each agent-loop iteration
- `ask` requests JSON object output and decodes the first choice only
- `solveWithAgent` runs a ReAct loop: it sends the transcript, executes any tool calls via the
  registered `ToolCallExec`, appends results, and repeats until the model returns a final answer
  or `agentMaxIterations` is exhausted
- logs decode failures and agent tool calls/results as sensitive log messages with the current
  logging context
- returns `Nothing` when decoding fails, content is absent, or the iteration budget is exhausted

Wrap AI scripts with `aiScript`.

## Tool-Aware AI Scripts

The `AIScriptDef` constructor accepts a list of `ToolDescription` values as its
first argument:

```haskell
AIScriptDef :: [ToolDescription] -> AIScript b -> Script b
```

`aiScript` passes an empty list (`[]`) for backward compatibility. When services are
registered via `makeServiceLib` with tool specs (see [extension.md](extension.md)), TH generates:

- `aiScriptWithAll :: AIScript b -> Script b` — passes all registered tool descriptions
- `aiScriptWith :: [LibTool] -> AIScript b -> Script b` — passes a subset

This lets the AI runtime know which tools (services) it can call.

## Review Checklist

- Are requests built via `mkAIRequest` / `mkAgentRequest` (or explicit `requestParams` / `agentParams`)?
- Do `AIParams` merges rely on right bias rather than concatenation?
- Is the `Conversation` built only via `emptyConversation` / `conversationFromTurns` (no leading `Chat.System` message, no pattern-matching on the unexported constructor)?
