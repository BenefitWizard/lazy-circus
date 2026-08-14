# AIRequest / AgentRequest vs OpenAI API

Сопоставление параметров `CreateChatCompletion` (из библиотеки `openai`,
форк `Ecialo/openai@08424bd`) с тем, что пользователь может сконфигурировать в
`AIRequest` / `AgentRequest` из `LazyCircus.AI`.

Источник истины: `src/LazyCircus/AI.hs`.

---

## Что настраивается в запросе

| Параметр OpenAI | Как задаётся в LazyCircus | Где |
|---|---|---|
| `messages` (user content) | `prompt :: [POML]` | `AIRequest` / `AgentRequest` |
| `messages` (system content) | `systemPrompt :: [POML]` | `AIRequest` / `AgentRequest` |
| `messages` (history) | `Conversation` (аргумент `*Continuing`) | не в рекорде |
| `extra` (частично) | `thinkingEnabled :: Bool` → `{"thinking":{"type":"enabled"}}` | `AIRequest` / `AgentRequest` |
| `model` | `aiModel` (`withModel`; fallback `defaultModel`) | `AIParams` |
| `temperature` | `aiTemperature` (`withTemperature`) | `AIParams` |
| `top_p` | `aiTopP` (`withTopP`) | `AIParams` |
| `max_completion_tokens` | `aiMaxCompletionTokens` (`withMaxCompletionTokens`) | `AIParams` |
| `seed` | `aiSeed` (`withSeed`) | `AIParams` |
| `frequency_penalty` | `aiFrequencyPenalty` (`withFrequencyPenalty`) | `AIParams` |
| `presence_penalty` | `aiPresencePenalty` (`withPresencePenalty`) | `AIParams` |
| `stop` | `aiStop` (`withStop`) | `AIParams` |
| `user` | `aiUser` (`withUser`) | `AIParams` |
| `reasoning_effort` | `aiReasoningEffort` (`withReasoningEffort`) | `AIParams` |

## AIParams: моноид и смарт-конструкторы

`AIParams` — рекорд из `Maybe`-полей, встраиваемый в реквесты как
`requestParams` (`AIRequest`) / `agentParams` (`AgentRequest`).
Применяется внутренней функцией `applyParams` поверх базового запроса в
`askAIContinuing` и на каждой итерации agent-loop.

- `Semigroup` / `Monoid` с **right bias**: `p1 <> p2` — `Just`-поля правого
  операнда выигрывают; списки (`aiStop`) переопределяются, а не конкатенируются.
  Это открывает паттерн `defaults <> overrides` для будущих env-дефолтов.
- Каждый `with*` возвращает одно-полевой фрагмент:

```haskell
req = (mkAgentRequest prompt sys 10)
    { agentParams = withModel "deepseek-reasoner"
        <> withTemperature 0.7
        <> withMaxCompletionTokens 4096
    }
```

- `mkAIRequest prompt systemPrompt` / `mkAgentRequest prompt sys maxIters` —
  смарт-конструкторы реквестов (`thinkingEnabled = False`, параметры `mempty`);
  фантомный тип ответа выводится из сигнатуры, `Proxy` больше не нужен.

## Что захардкожено / задано не из реквеста

| Параметр OpenAI | Значение | Где |
|---|---|---|
| `response_format` | `JSON_Object` — только для `askAIContinuing`; `Nothing` для agent-loop | `AI.hs`, намеренно: декодинг `askAIContinuing` опирается на JSON-ответ; agent-loop должен уметь возвращать `tool_calls` |
| `tools` / `tool_choice` | берутся из окружения (`HasToolDescriptions`, `aiScriptWith`), не из реквеста | `AI.hs` / `Scene.AI` |
| `model` (fallback) | `"deepseek-v4-flash"` (`defaultModel`) — только когда `aiModel = Nothing` | `AI.hs` |
| `outputType` (phantom) | косвенно выбирает целевой тип JSON-декодинга | `AI.hs` |

Сознательно НЕ экспонируются через `AIParams`:

- `response_format` — ломает контракт декодинга (см. таблицу выше);
- `tools` / `tool_choice` — архитектурно принадлежат сцене/окружению
  (`aiScript` / `aiScriptWith` / `aiScriptWithAll`);
- сырой `extra` (`Maybe Object`) — конфликтовал бы с `thinkingEnabled`;
  DeepSeek-специфика остаётся за булевым флагом.

## Что вообще не настраивается (`Nothing` по умолчанию)

| Параметр OpenAI | Краткое назначение |
|---|---|
| `n` | число вариантов |
| `logprobs` / `top_logprobs` | log-prob токенов |
| `logit_bias` | bias на токены |
| `store` | хранение на стороне OpenAI |
| `metadata` | метаданные запроса |
| `service_tier` | latency-tier |
| `stream` / `stream_options` | стриминг |
| `modalities` / `audio` | аудио-модальности |
| `prediction` | predicted output |
| `parallel_tool_calls` | параллельные tool calls |
| `web_search_options` | веб-поиск |

## Специфичные для LazyCircus (не из OpenAI API)

| Поле | Назначение |
|---|---|
| `agentMaxIterations :: Natural` | бюджет итераций ReAct-цикла (`AgentRequest` только) |
| `thinkingEnabled :: Bool` | DeepSeek thinking mode (через `extra`) |

## Резюме

Из ~28 параметров `CreateChatCompletion` пользователь контролирует:
**3** поля самого реквеста (`prompt`, `systemPrompt`, `thinkingEnabled`) +
историю через `Conversation` + **10** sampling/identity-параметров через
моноид `AIParams` (`model`, `temperature`, `top_p`, `max_completion_tokens`,
`seed`, `frequency_penalty`, `presence_penalty`, `stop`, `user`,
`reasoning_effort`). `response_format` зафиксирован намеренно, `tools` живут в
окружении, остальные экзотические параметры (`logprobs`, `logit_bias`,
`metadata`, стриминг, аудио, …) пока не пробрасываются.
