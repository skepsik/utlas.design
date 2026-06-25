# LLM tools

Инфраструктура **tool loop**: модель возвращает `toolCalls` в [answer envelope](../envelope/index.md) — атомарные tools или **`composite`** (цепочки). Backend выполняет runners, результат → следующий LLM call (или финальный answer).

**Work:** [#38](https://github.com/skepsik/utlas-ts/issues/38) (loop + composite). Контракты — страницы ниже.

---

## Tool loop (v0)

```text
LLM answer { toolCalls? }
  → execute → tool result JSON (→ ToolRunResult после [#68](https://github.com/skepsik/utlas-ts/issues/68))
  → tool results → next LLM call (loop) или final answer
  → declarative patches — после loop
  → deliver если shouldReply
```

**Первый этап с моделью:** [#67](https://github.com/skepsik/utlas-ts/issues/67) — только `show_map_pin` после [#65](https://github.com/skepsik/utlas-ts/issues/65).

Координаты и факты из чата **не trust** — только tool output.

---

## Размещение

```text
tools/registry/         atoms + chain edges (composite)
tools/runners/          instruments (geocode, map-pin, …)
turn/run-turn.ts        tool loop wiring
llm/                    adapter structured output, wire schema
transport/              egress side-effects (sendLocation, …)
```

Transport не импортирует `llm/`; turn склеивает.

**Решения:** [composite](./composite.md) (цепочки, память) · [native-tool-calls](./native-tool-calls.md) (**Rejected**).

---

## Tool registry

Turn знает набор wired tools (v0: фиксированный; later: policy / per-tenant).

Каждый tool: `name`, JSON schema args, runner в `tools/runners/`. Цепочки — **рёбра** между атомами, см. [composite](./composite.md).

| Tool / механизм | Страница |
|-----------------|----------|
| `geocode_place`, `show_map_pin` | [geocode](./geocode.md) · [composite](./composite.md) |
| `composite` | [composite](./composite.md) |
| `search_messages` | [message-search](./message-search.md) |

---

## Prompt

Два слоя — как у system blocks ([turn-prompt](../turn-prompt.md)):

### 1. `availableToolsResolver` (system)

Динамическая секция из tool registry turn'а:

- для каждого wired tool: `name`, краткое `description` (из schema);
- только tools, доступные в этом turn;
- если tools не подключены — resolver **omit**.

```text
AVAILABLE TOOLS
- geocode_place(query) — …
- search_messages(query) — …
```

Registry в `PromptComposer` deps → `PromptContext` (не hardcode в resolver).

### 2. PG block `tools` (policy)

Статичная policy: когда вызывать tools, **паттерны** (composite vs atom), не выдумывать координаты — [composite](./composite.md) § Стартовые кейсы.

`createTextBlockResolver("tools")` в **defaultSystemResolvers** — после `turn_handling`, рядом с `availableToolsResolver`.

Seed в migration; tuning later.

**Не смешивать** с PG block `response_format` (JSON answer schema) — [envelope](../envelope/index.md).

---

## Цель

- [ ] Tool loop в `runTurn` ([#38](https://github.com/skepsik/utlas-ts/issues/38))
- [ ] `availableToolsResolver` + registry в PromptComposer deps
- [ ] PG block `tools` + seed

## Later

- [ ] Parallel executor
