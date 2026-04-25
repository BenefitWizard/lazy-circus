# DeepSeek API — Руководство

> Документация основана на данных с https://api-docs.deepseek.com/ на апрель 2026.

---

## Модели и цена

| | deepseek-v4-flash | deepseek-v4-pro |
|---|---|---|
| Версия модели | DeepSeek-V4-Flash | DeepSeek-V4-Pro |
| Контекст | 1M токенов | 1M токенов |
| Максимальный вывод | 384K токенов | 384K токенов |
| Thinking Mode | non-thinking + thinking (по умолч.) | non-thinking + thinking (по умолч.) |
| 1M входных токенов (cache hit) | $0.028 | $0.03625\* |
| 1M входных токенов (cache miss) | $0.14 | $0.435\* |
| 1M выходных токенов | $0.28 | $0.87\* |

\* deepseek-v4-pro — временная скидка 75% (до 2026/05/05), обычная цена: $0.145 / $1.74 / $3.48.

Устаревшие имена `deepseek-chat` и `deepseek-reasoner` будут отключены 2026/07/24; они маппятся на non-thinking и thinking режимы `deepseek-v4-flash`.

---

## Подключение

API совместим с форматом OpenAI и Anthropic:

| Параметр | Значение |
|---|---|
| `base_url` (OpenAI) | `https://api.deepseek.com` |
| `base_url` (Anthropic) | `https://api.deepseek.com/anthropic` |
| `api_key` | получить на platform.deepseek.com |
| `model` | `deepseek-v4-flash` или `deepseek-v4-pro` |

### Пример (Python, OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(
    api_key="DEEPSEEK_API_KEY",
    base_url="https://api.deepseek.com",
)

response = client.chat.completions.create(
    model="deepseek-v4-pro",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "Hello!"},
    ],
    stream=False,
    reasoning_effort="high",
    extra_body={"thinking": {"type": "enabled"}},
)

print(response.choices[0].message.content)
```

### Пример (curl)

```bash
curl https://api.deepseek.com/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
  -d '{
    "model": "deepseek-v4-pro",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Hello!"}
    ],
    "thinking": {"type": "enabled"},
    "reasoning_effort": "high",
    "stream": false
  }'
```

---

## Thinking Mode (режим рассуждений)

Модель перед финальным ответом генерирует цепочку рассуждений (chain-of-thought), что повышает точность.

### Управление

| Параметр | OpenAI формат | Anthropic формат |
|---|---|---|
| Включение/выключение | `extra_body={"thinking": {"type": "enabled"/"disabled"}}` | — |
| Уровень усилия | `reasoning_effort`: `"high"` / `"max"` | `output_config.effort`: `"high"` / `"max"` |

- По умолчанию thinking включён, effort = `high`.
- Для агентных задач (Claude Code, OpenCode и т.п.) автоматически ставится `max`.
- `low` и `medium` маппятся в `high`; `xhigh` — в `max`.

### Ограничения

- Параметры `temperature`, `top_p`, `presence_penalty`, `frequency_penalty` **игнорируются** в thinking mode (ошибки не вызывают).
- Цепочка рассуждений возвращается в поле `reasoning_content` на одном уровне с `content`.

### Мультираунд без tool calls

`reasoning_content` от предыдущих раундов **не нужно** передавать обратно — API его проигнорирует.

```python
messages.append(response.choices[0].message)  # content + reasoning_content
messages.append({"role": "user", "content": "Next question?"})
```

### Мультираунд с tool calls

Если модель делала tool call, `reasoning_content` **обязательно** передавать во всех последующих запросах — иначе API вернёт ошибку 400.

---

## Tool Calls (вызов функций)

Модель может вызывать определённые пользователем функции в ходе генерации ответа.

### Пример (non-thinking mode)

```python
tools = [
    {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get weather of a location",
            "parameters": {
                "type": "object",
                "properties": {
                    "location": {"type": "string", "description": "City name"},
                },
                "required": ["location"],
            },
        },
    },
]

message = client.chat.completions.create(
    model="deepseek-v4-pro",
    messages=[{"role": "user", "content": "How's the weather in Hangzhou?"}],
    tools=tools,
).choices[0].message

# message.tool_calls[0] → вызов get_weather({location: "Hangzhou"})
```

### strict-режим (Beta)

Гарантирует, что аргументы tool call строго соответствуют JSON Schema.

Требуется:

1. `base_url="https://api.deepseek.com/beta"`
2. `"strict": true` в каждом `function`

Поддерживаемые типы JSON Schema: `object`, `string`, `number`, `integer`, `boolean`, `array`, `enum`, `anyOf`, `$ref`/`$def`.

---

## JSON Output

Структурированный вывод в формате JSON.

```python
response = client.chat.completions.create(
    model="deepseek-v4-pro",
    messages=[
        {"role": "system", "content": 'Return JSON: {"question": "...", "answer": "..."}'},
        {"role": "user", "content": "What is the capital of France?"},
    ],
    response_format={"type": "json_object"},
)
```

**Важно:**

- Слово «json» должно присутствовать в промпте + пример формата.
- Устанавливайте `max_tokens` достаточного размера.
- API может иногда возвращать пустой content — корректируйте промпт.

---

## Chat Prefix Completion (Beta)

Задаёт префикс ответа assistant, модель продолжает его.

```python
client = OpenAI(api_key="...", base_url="https://api.deepseek.com/beta")

messages = [
    {"role": "user", "content": "Write quick sort code"},
    {"role": "assistant", "content": "```python\n", "prefix": True},
]
response = client.chat.completions.create(
    model="deepseek-v4-pro",
    messages=messages,
    stop=["```"],
)
```

---

## FIM Completion (Fill In the Middle) (Beta)

Модель заполняет текст между заданными prefix и suffix. Полезно для автодополнения кода.

```python
client = OpenAI(api_key="...", base_url="https://api.deepseek.com/beta")

response = client.completions.create(
    model="deepseek-v4-pro",
    prompt="def fib(a):",
    suffix="    return fib(a-1) + fib(a-2)",
    max_tokens=128,
)
print(response.choices[0].text)
```

- Макс. 4K токенов для FIM.
- Использует endpoint `/completions` (не `/chat/completions`).
- Интеграция с [Continue](https://continue.dev) для VS Code.

---

## Context Caching (кэширование контекста)

Включено по умолчанию для всех пользователей. Повторяющиеся префиксы запросов кэшируются на диск — попавшие в кэш токены тарифицируются по цене cache hit.

### Правила попадания в кэш

- Кэш-юниты создаются на границе конца user input и конца model output.
- Система автоматически выявляет общий префикс у нескольких запросов и кэширует его.
- Для длинных текстов кэш-юниты создаются через фиксированные интервалы токенов.

### Проверка попадания в кэш

В поле `usage` ответа:

- `prompt_cache_hit_tokens` — токены, попавшие в кэш.
- `prompt_cache_miss_tokens` — токены без кэша.

### Примечания

- Кэш работает «best-effort», не гарантирует 100% hit rate.
- Неиспользуемый кэш очищается через несколько часов / дней.

---

## Rate Limits

DeepSeek динамически ограничивает конкурентность на основе нагрузки сервера. При достижении лимита — HTTP 429.

- Не-streaming запросы возвращают пустые строки, пока ждут.
- Streaming запросы возвращают SSE-комментарии `: keep-alive`.
- Если запрос не начал инференс за 10 минут — сервер закрывает соединение.

---

## Возможности моделей — сводка

| Возможность | deepseek-v4-flash | deepseek-v4-pro |
|---|---|---|
| Thinking Mode | да | да |
| Non-thinking Mode | да | да |
| JSON Output | да | да |
| Tool Calls | да | да |
| Chat Prefix Completion (Beta) | да | да |
| FIM Completion (Beta) | non-thinking только | non-thinking только |
| Context Caching | да | да |
| Anthropic API формат | да | да |
| Контекст до 1M токенов | да | да |
| Макс. вывод 384K токенов | да | да |
