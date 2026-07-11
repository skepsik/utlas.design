# Native tool calls и multi-message API

**Решение:** tool execute через `toolCalls?` в [answer envelope](../envelope/index.md) (**structured output**), не через native tools API провайдера (Gemini `tools`, Anthropic `tool_use`, и т.п.). Turn prompt — **`LlmPrompt { system, user }`** (compose → один user blob), **не** провайдерский `messages[]` как канон wire.

См. также: [tools](./index.md), [envelope](../envelope/index.md), [llm-jobs](../llm-jobs.md), [semantic-thread](../semantic-thread.md) § Подача модели.

Страница фиксирует **Rejected** для native tools и multi-message и порог **пересмотра**, чтобы не спорить заново при росте каталога tools.

---

## Зачем

Один turn уже держит **structured `LlmAnswer`**: `shouldReply`, `text`, declare-patches, позже `toolCalls`. Альтернатива — отдельный канал «провайдер вызвал tool» на каждом шаге **tool loop** плюс тот же envelope для declare и deliver; либо **multi-message** `messages[]`, где лента и tool hop'ы — рост provider thread.

Обсуждение (2026-07): multi-message **не обязателен** для envelope `toolCalls`, но **несколько inference подряд в одном turn** при растущем `messages[]` **по смыслу** требует tool-shaped hop'ов между вызовами — иначе каждый hop всё равно сводится к re-compose. Мы сознательно держим **re-compose** и **не** растим provider thread.

---

## Сейчас vs цель

| Аспект | Сейчас (v0) | Цель |
|--------|-------------|------|
| Форма вызова tool | нет `toolCalls` в zod ([#38](https://github.com/skepsik/utlas-ts/issues/38)) | optional `toolCalls[]` в `LlmAnswer` |
| Wire в adapter | `responseSchema` / `json_schema` на весь answer | то же + поле `toolCalls` |
| Turn prompt wire | `{ system, user }` — секции `=== … ===` в user | то же |
| Список tools для модели | prompt (`availableToolsResolver` + PG `tools`) | registry → subset на turn + caching на входе |
| Исполнение | — | executor + `tools/runners/`; parallel — в executor |
| Native API tools | не используем | **Rejected** (§ ниже) |
| Multi-message API | не используем | **Rejected** (§ ниже) |

**Инвариант:** один JSON-ответ на inference-шаг cascade; parse → `parseLlmAnswer`; declare и deliver — после **tool loop**, не внутри vendor tool channel. Состояние hop'ов — **orchestrator + compose**, не ownership провайдера над `messages[]`.

---

## Wire kanon: blob + re-compose

```text
compose → LlmPrompt { system, user }
adapter → один user message (+ system / system_instruction)
```

Лента чата, `[THREAD]` / `[reply to]`, compose blocks, tool results — **сериализация в user** (секции, append). История бота в prompt v0 — тоже текст в ленте (`(bot)` в header), не отдельные `assistant` role на wire.

**Tool loop** — не рост `messages[]` у провайдера:

```text
LLM → LlmAnswer { shouldReply, text, toolCalls? }
  → если toolCalls: execute (registry) → inject results в compose → compose заново → снова LLM
  → cap итераций
  → declarative patches (conversationSettings, …)
  → deliver если shouldReply
```

Промежуточный шаг с tools: **`shouldReply: false`, `text: ""`** — без user-visible текста до финала. Egress side-effects (pin) — из tool runner, не из `text`.

Параллельные вызовы — **`toolCalls[]` массив**; parallel run — **executor** (`Promise.all` где нет зависимостей).

Injection v0: append `--- TOOL RESULTS ---` к user string ([#67](https://github.com/skepsik/utlas-ts/issues/67)); целевой — секция в compose, **без** смены wire shape.

---

## Inference — точки, не цепь провайдера

[llm-jobs](../llm-jobs.md): **invoke** (raw) отдельно от parse / tool loop / deliver. Несколько LLM за turn — **наши** hop'ы с re-compose, не conversation thread vendor'а.

**Почему не цепь `messages[]`:**

- **Supersede / cancel** ([turn-pipeline](../turn-pipeline.md)) — скобка `runTurn`; partial provider thread после supersede привязать к turn сложнее, чем отбросить compose state.
- **Долгоиграющие job**, уточнение статуса, **HITL** — отдельный ingress → отдельный run; не v1 в hot loop ([turn-pipeline](../turn-pipeline.md)).
- **Recall LLM**, inference в resolvers — короткий profile + узкий parse; не продолжение того же `messages[]`, что answer-turn.

Если inference = **несвязанная точка** — решаемо. Если **гарантированная цепь** у провайдера — порядок сложнее; мы эту модель **не** принимаем.

---

## Масштабирование tools без native

Рост каталога давит на **вход** и **registry**, не на форму ответа:

- **Tool registry** — `name`, description, args schema, runner
- **Per-turn subset** — в prompt только tools, доступные в этом turn
- **Prompt caching** — статический PG block `tools` + короткий dynamic list
- **Валидация args** — zod в executor после parse

---

## Rejected

### Native provider tool calls

**Не делаем:** отдельный путь Gemini `tools` / Anthropic `tool_use` / function-calling parts вместо `toolCalls` в `LlmAnswer`.

**Почему:**

- **Два стека на один turn** — native execute в loop **и** structured envelope для `shouldReply`, declare, cascade.
- **Нюансы провайдеров на каждой итерации** — tool definitions, tool results, multi-turn tool messages **отдельно на Gemini и Anthropic**.
- **Declare в envelope** — `conversationSettings`, `blockTtl`, `scratchpad` native channel не покрывает.
- **Registry и executor** — нужны в любом случае; native не заменяет.
- **Concurrency** — tool loop + supersede + долгие side effects проще, когда hop state у **нас**, не у vendor thread.

### Multi-message API (`messages[]` как канon turn prompt)

**Не делаем:** replay ленты как нативный массив `{ role, content }` вместо одного user blob; рост provider thread между hop'ами tool loop.

**Почему:**

- **Несколько inference подряд** при растущем `messages[]` требует tool-shaped hop'ов (native `tool_result` или fake user/assistant) — та же сложность цепи, которую избегаем; **re-compose blob** достаточен.
- **Чередование role** — Anthropic: user ↔ assistant; group burst `user-user-user` → **склейка** или костыли; OpenAI `name` — vendor-specific, не единый wire.
- **Ложная иерархия** — несколько участников в **одном** native `user`: API = «один user turn», speaker только из текста (`[Alice]:` …); **хуже**, чем плоский blob, где никто не притворяется одним user.
- **Group** — bot `assistant` vs люди `user` не совпадает с «все в ленте равны по format»; blob честнее: speaker всегда в content, без противоречия role.
- **Размер окна не аргумент** — multi-message **не упрощает** большое окно: те же токены, те же проблемы (group, tool loop, supersede); overhead role/part на message может быть **выше**, чем у blob.
- **Не следует** из отказа от блока **SEMANTIC THREAD** — `[THREAD]` маркер совместим с blob ([semantic-thread](../semantic-thread.md) § Подача модели).

**Связь с native tools:** orthogonal (можно было бы multi-message без native tools), но **практически** multi-hop turn тянет tool-shaped chain; мы отказываемся от **обоих** в пользу orchestrator + blob.

### «Много tools ⇒ native» / «большое окно ⇒ multi-message»

**Не делаем** как автоматический переход. Multi-message **не** решает большое окно — только меняет упаковку тех же реплик. Сначала registry, subset, caching, compose injection; архив старше окна — [message-search](./message-search.md) + [compose-blocks](../envelope/compose-blocks.md), без смены wire.

---

## Пересмотр (revisit)

Порядок: **сначала** исчерпать улучшения на нашей стороне, **потом** сравнивать с native / multi-message.

### 1. Сначала (не native, не multi-message)

- Prompt tools — PG, subset, caching, executor zod
- Tool results — секции compose, compose blocks TTL
- Presentation thread — убрать duplicate **SEMANTIC THREAD** block, `[THREAD]` в ленте (blob не меняется)

### 2. Потом (только по стабильным метрикам)

| Сигнал | Что сравниваем |
|--------|----------------|
| Качество вызова tool | wrong name/args: native vs envelope при **том же** prompt |
| Длинный tool loop | inject в compose vs vendor `tool_result` после N hop'ов |
| Group quality | blob vs multi-message на **реальных** логах, не synthetic worst case |

До § 2 — один envelope, один wire `{ system, user }`, re-compose loop.

---

## Later

- Parallel tool executor (dependency graph)
- Per-tenant / policy-driven tool subset
- Prompt caching для тяжёлого `availableToolsResolver`

---

## Out of scope

- MCP как transport tools
- Computer use / vendor-specific modalities
- Multi-message только для private при сохранении blob для group — **не** планируем без § 2 revisit
