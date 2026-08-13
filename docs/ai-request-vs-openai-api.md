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

## Что захардкожено / задано не из реквеста

| Параметр OpenAI | Значение | Где |
|---|---|---|
| `model` | `"deepseek-v4-flash"` (`defaultModel`) | `AI.hs:57,151,284` |
| `response_format` | `JSON_Object` — только для `askAIContinuing`; `Nothing` для agent-loop | `AI.hs:152`, намеренно опущен в `AI.hs:290-292` |
| `tools` / `tool_choice` | берутся из окружения (`HasToolDescriptions`), не из реквеста | `AI.hs:278-287` |
| `outputType` (phantom) | косвенно выбирает целевой тип JSON-декодинга | `AI.hs:51` |

## Что вообще не настраивается (`Nothing` по умолчанию)

| Параметр OpenAI | Краткое назначение |
|---|---|
| `temperature` | рандомность |
| `top_p` | nucleus sampling |
| `max_completion_tokens` | лимит длины ответа |
| `frequency_penalty` / `presence_penalty` | штрафы за повторения/новизну |
| `seed` | воспроизводимость |
| `stop` | стоп-последовательности |
| `n` | число вариантов |
| `logprobs` / `top_logprobs` | log-prob токенов |
| `logit_bias` | bias на токены |
| `user` | идентификатор end-user |
| `store` | хранение на стороне OpenAI |
| `metadata` | метаданные запроса |
| `service_tier` | latency-tier |
| `reasoning_effort` | глубина reasoning для reasoning-моделей |
| `stream` / `stream_options` | стриминг |
| `modalities` / `audio` | аудио-модальности |
| `prediction` | predicted output |
| `parallel_tool_calls` | параллельные tool calls |
| `web_search_options` | веб-поиск |

## Специфичные для LazyCircus (не из OpenAI API)

| Поле | Назначение |
|---|---|
| `agentMaxIterations :: Natural` | бюджет итераций ReAct-цикла (`AgentRequest` только) |

## Резюме

Из ~28 параметров `CreateChatCompletion` пользователь реально контролирует
только **3** через реквест (`prompt`, `systemPrompt`, `thinkingEnabled`) +
историю через `Conversation`. Остальное: `model` захардкожден,
`response_format` зафиксирован, `tools` живут в окружении, а все
sampling-параметры (`temperature`, `top_p`, `max_completion_tokens`, …)
вообще не пробрасываются.
