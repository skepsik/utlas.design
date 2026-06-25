# Native tool calls (провайдер)

**Решение:** tool execute через `toolCalls?` в [answer envelope](../envelope/index.md) (**structured output**), не через native tools API провайдера (Gemini `tools`, Anthropic `tool_use`, и т.п.).

См. также: [tools](./index.md), [envelope](../envelope/index.md), [llm-jobs](../llm-jobs.md).

---

## Зачем

Один turn уже держит **structured `LlmAnswer`**: `shouldReply`, `text`, declare-patches, позже `toolCalls`. Альтернатива — отдельный канал «провайдер вызвал tool» на каждом шаге **tool loop** плюс тот же envelope для declare и deliver.

Страница фиксирует **Rejected** и порог **пересмотра**, чтобы не спорить заново при росте каталога tools.

---

## Сейчас vs цель

| Аспект | Сейчас (v0) | Цель |
|--------|-------------|------|
| Форма вызова tool | нет `toolCalls` в zod ([#38](https://github.com/skepsik/utlas-ts/issues/38)) | optional `toolCalls[]` в `LlmAnswer` |
| Wire в adapter | `responseSchema` / `json_schema` на весь answer | то же + поле `toolCalls` |
| Список tools для модели | prompt (`availableToolsResolver` + PG `tools`) | registry → subset на turn + caching на входе |
| Исполнение | — | executor + `tools/runners/`; parallel — в executor |
| Native API tools | не используем | **Rejected** (§ ниже) |

**Инвариант:** один JSON-ответ на inference-шаг cascade; parse → `parseLlmAnswer`; declare и deliver — после **tool loop**, не внутри vendor tool channel.

---

## Tool loop (канон)

```text
LLM → LlmAnswer { shouldReply, text, toolCalls? }
  → если toolCalls: execute (registry) → tool results в compose → снова LLM
  → cap итераций
  → declarative patches (conversationSettings, …)
  → deliver если shouldReply
```

Промежуточный шаг с tools: **`shouldReply: false`, `text: ""`** — без user-visible текста до финала (нет edit сообщений в Telegram). Egress side-effects (pin) — из tool runner, не из `text`.

Параллельные вызовы в одном ответе — **`toolCalls[]` массив**; parallel run — **executor** (`Promise.all` где нет зависимостей), не фича native API.

---

## Масштабирование без native

Рост каталога (десятки tools, тяжёлые defs) давит на **вход** и **registry**, не на форму ответа:

- **Tool registry** — `name`, description, args schema, runner
- **Per-turn subset** — в prompt только tools, доступные в этом turn
- **Prompt caching** — статический PG block `tools` + короткий dynamic list
- **Валидация args** — zod в executor после parse

Ответ модели остаётся компактным: массив `{ name, arguments }`, без дублирования всех tool schemas в `responseSchema`.

---

## Rejected

### Native provider tool calls

**Не делаем:** отдельный путь Gemini `tools` / Anthropic `tool_use` / function-calling parts вместо `toolCalls` в `LlmAnswer`.

**Почему:**

- **Два стека на один turn** — native execute в loop **и** structured envelope для `shouldReply`, declare, cascade. Hybrid дороже одного parse path.
- **Нюансы провайдеров размазаны по loop** — помимо уже существующей нормализации wire schema в adapter пришлось бы переводить tool definitions, tool results, multi-turn tool messages **отдельно на Gemini и Anthropic** на **каждой** итерации loop.
- **Смешение с declare** — `conversationSettings`, `blockTtl`, `scratchpad` живут в том же answer object; native channel их не покрывает, всё равно остаётся envelope.
- **Registry и executor нужны в любом случае** — native не заменяет `tools/runners/`, subsetting, parallel executor.
- **Параллель** — не дар native API; тот же `toolCalls[]` + наш executor.

Агностицизм к провайдеру **не бесплатен**, но узкий: vendor-specific слой сосредоточен в **adapter structured output** (уже есть). Второй vendor-specific слой на tool loop — это и есть удорожание, которого избегаем.

### «Много tools ⇒ native»

**Не делаем** как автоматический переход: сначала registry, subset, caching на входе, parallel executor. См. § Масштабирование.

---

## Пересмотр (revisit)

Порядок обязателен: **сначала** исчерпать улучшения на нашей стороне, **потом** сравнивать с native.

### 1. Сначала (не native)

При плохом quality вызова или росте каталога — до любого A/B с провайдерским API:

- **Prompt** — PG block `tools`, policy в `availableToolsResolver`, примеры цепочек, anti-patterns (не выдумывать coords и т.п.)
- **Per-turn subset** — сузить список tools до релевантных transport × capabilities × policy; убрать шум из dynamic list
- **Prompt caching** — статика в PG, dynamic list короткий
- **Executor** — валидация args (zod), понятные tool results в compose

Только если после итераций по этому слою проблема **стабильно** остаётся — переходим к § 2.

### 2. Потом native (только по метрикам)

Не по росту списка tools и не «модель плохо вызвала один раз»:

| Сигнал | Что сравниваем |
|--------|----------------|
| Качество вызова | стабильно выше wrong name/args на native при **том же** оттюненном prompt и subset |
| Длинный tool loop | custom injection tool results в compose хуже vendor `tool_result` messages после N раундов — при прочих равных |
| Экономика | измеримый выигрыш **только** на API tool-def cache; prompt caching + subset не закрывают |

До срабатывания § 2 — один envelope, один loop, один adapter path.

---

## Later

- Parallel tool executor (dependency graph)
- Per-tenant / policy-driven tool subset
- Prompt caching для тяжёлого `availableToolsResolver`

---

## Out of scope

- MCP как transport tools
- Computer use / vendor-specific modalities
