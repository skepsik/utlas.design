# LLM tools

Инфраструктура **tool loop**: модель возвращает `toolCalls` в [answer envelope](../envelope/index.md), backend выполняет runners, результат → следующий LLM call (или финальный answer).

**Work:** [#38](https://github.com/skepsik/utlas-ts/issues/38) (geocode E2E). Контракты tools — страницы ниже.

---

## Tool loop (v0)

```text
LLM answer { toolCalls? }
  → execute tools sequentially (cap итераций)
  → tool results → next LLM call (loop) или final answer
  → declarative patches (scratchpad, blockTtl, …) — после loop
  → egress если shouldReply
```

- v0: **sequential** execution.
- Later: parallel executor с dependency graph (независимые tools параллельно, цепочки sequential).

Координаты и факты из чата **не trust** — только tool output.

---

## Размещение

```text
tools/runners/          instruments (geocode, message-search, …)
turn/run-turn.ts        tool loop wiring
llm/                    adapter function calling, tool defs
transport/              egress side-effects (sendLocation, …)
```

Transport не импортирует `llm/`; turn склеивает.

---

## Tool registry

Turn знает набор wired tools (v0: фиксированный; later: policy / per-tenant).

Каждый tool: `name`, JSON schema args, runner в `tools/runners/`.

| Tool | Страница |
|------|----------|
| `geocode_place`, `send_map_pin` | [geocode](./geocode.md) |
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

Статичная policy: когда вызывать tools, цепочки (geocode → pin), не выдумывать координаты.

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
