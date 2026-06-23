# Turn pipeline

**Turn / pipeline** — скобка конкурентности (`turn.start` / `turn.stop`), сценарий шагов orchestrator'а и default path user→bot. Transport ([transport](./transport.md)) вызывает `runTurn`; domain ([domain](./domain.md)) agnostic.

**v0 в коде** — monolith `runTurn` + supersede до send. Ниже — **north star**; implementation — отдельные work issues.

Источник обсуждения: `turn-pipeline-discussion.md` (transcript 2026-06).

---

## Термины

| Термин | Смысл |
|--------|--------|
| **Turn** | только **`turn.start` / `turn.stop`** — скобка конкурентности (supersede, in-flight) |
| **Pipeline** | сценарий шагов; **0..N** turn-скобок в теории, **v1: 0 или 1** |
| **Ingress** | опциональный шаг: событие → anchor (+ persist). Transport делает до runner |
| **Deliver** | опциональный шаг: отправка в мессенджer (бывший egress-**шаг**, не скобка) |

**Не путать:** ingress / deliver — **шаги pipeline**, не синонимы start/stop.

---

## v0 (код сейчас)

```
transport: persistIngress → qualifiesForTurn? → runTurn(TurnRequest)
runTurn:
  bot_enabled → onNewTurnMessage (supersede?) → GenerationTask
  enrichment → context → LLM → replySender.sendReply + saveBotReply
  shouldDiscardOnSend → clearActiveAfterSend   ← stop привязан к send, не к inference
```

| | v0 | Target |
|---|-----|--------|
| Скобка | неявная, до send | `turn.start` … `turn.stop` |
| Deliver | всегда после LLM | `deliver if should_reply` |
| Burst | cancel task + discard send | re-enter pipeline с `turn.start` |
| State | module-global Map | injectable store (tech debt) |

`/ask`: **ingress есть** (`persistIngress` + `textOverride`), отличие — только **нет gate**; отдельного pipeline не нужно.

---

## Целевой default pipeline

Один граф для всех user-message path (включая «будильник, молчи»):

```yaml
- ingress: {}              # или transport до runner
- turn.start: {}

- build_context: {}
- llm:
    slot: answer             # structured: should_reply + content + actions/plan

- turn.stop: {}             # явный шаг сценария, не автоматика в llm/

- connector: {}             # 0..N, post-turn
- deliver:
    if: should_reply         # false → no-op
```

**Контракт default inference:** модель **всегда** возвращает `should_reply` (и outcome). Parse fail / битый JSON → **`should_reply: true`** + log (edge case).

**Порядок:** `turn.stop` **до** `deliver`. Post-turn write только после нормального stop.

---

## Burst и `turn.start`

`turn.start` = начало **тела итерации**, не «включи supersede навсегда».

```text
новое qualifying сообщение (в gap)
  → abort in-flight (AbortSignal)
  → re-enter pipeline с turn.start
  → … read/llm …
  → turn.stop
  → post-turn (если !aborted)
```

YAML: `turn.start` / `turn.stop` **один раз в файле**; runner **переисполняет** тело на каждый burst / ingress.

---

## Инвариант: read + LLM внутри скобки

Между `turn.start` и `turn.stop` **только read и LLM** (cancellation-safe):

| Разрешено | Запрещено |
|-----------|-----------|
| MessageReadPort, load context / graph | connector write |
| build_context, enrichment read-only | thread.append / persist graph |
| llm.generate (+ signal) | deliver, saveBotReply |

Ingress (persist входящего) — **до** `turn.start`.  
**Все write** (connector, deliver, audit batch, materialize thread) — **после** `turn.stop`.

Enforce: step kind + YAML validator + runner zones.

---

## Abort

**Каждый** orchestrator step — `AbortSignal` (не только turn).

При abort:

```text
turn.start
try:   read* → llm*
       turn.stop          # happy path — нормальное закрытие итерации
catch AbortError:
finally:
       turn.stop()        # только если start был и stop ещё нет
# post-turn — НЕ выполнять если aborted
```

**Abort внутри turn — три правила:**

| | Happy path | Abort |
|---|------------|-------|
| **`turn.stop` в try** | явный шаг pipeline; после него — post-turn write | не достигнут |
| **`turn.stop` в `finally`** | — | **только** снять supersede-scope; **не** write, **не** «догнать pipeline» |
| **Post-turn write** (deliver, connector, audit, …) | после try-stop | **не запускаются** |

`finally`-stop ≠ happy-path stop ≠ разрешение на deliver. Runner: pre-turn → turn body → turn close → **post-turn iff !aborted**.

---

## YAML validation (fail fast на load)

| Правило | |
|---------|---|
| `turn.start` → обязателен `turn.stop` | error |
| парность start/stop (стек) | error |
| `turn.stop` до `deliver` | error |
| write/deliver step между start и stop | error |
| неизвестный step | error |

Safety net: abort → `finally` stop; **не** замена валидатору.

Тест + `npm run check`: `default-turn.yaml` ok; fixture «start без stop» → throw.

---

## Orchestrator vs turn

- **Orchestrator / runner** — какие шаги, порядок; **потребляет** нити / граф через steps (`build_context`, later `thread.load`).
- **Turn** — только start/stop; **не** потребляет граф.

Classifier / local LLM → big LLM: обычные `llm` steps с `if`, та же скобка.

---

## Tech debt (v0)

- `turn-state.ts` — module-global Map, `getTurnState` без DI → injectable **TurnStateStore**
- `runTurn` monolith → runner + steps
- `replyToForAnchor` в turn vs `telegramReplyTo` в transport — dedupe отдельно ([transport](./transport.md))

---

## Out of scope (v1)

- **N > 1** turn-скобок в одном pipeline run (теория 0..N; **практика v1: 0 или 1**). Clarification loop / HITL — отдельные ingress → отдельные runs, не два turn в одном YAML.
- Tool calls / HITL pause в hot loop
- Persisted thread graph, decision graph (git-like commits)
- Расследование тишины на «привет, молчи» в prod (логи отдельно)

North star (не блокер v1): materialized semantic graph, post-stop append.

## Later: capabilities, tools, model constraints

Когда появятся tools / function calling, часть strategy (models без native tools) отпадает для tool-turn'ов. Это **не переделка composer** — расширение turn + llm контуров.

### Границы ответственности

| Слой | Роль |
|------|------|
| **Turn planner** (`turn/` или step `build_context`) | Snapshot на turn: `transport × model × connectors` → `TurnCapabilities` |
| **Strategy / router** | Steps с `supports_tools`; filter или отдельная named strategy для tool-turn |
| **Composer** ([turn-prompt](./turn-prompt.md)) | **Consumer** snapshot: optional текст в prompt; omit tool-blocks если `!supportsTools`. **Не** source of truth для tool list |
| **Adapter / `LlmProvider.generate`** | Wire: `tools` / `toolChoice` в API payload (native tools, не дублировать в system text без нужды) |

```text
availableTools = transportActions(transport)
               ∩ modelCapabilities(model|route)
               ∩ enabledClients
```

### Порядок (target, не ломает v0 composer)

```text
plan capabilities (transport + intended tools + strategy filter)
  → compose(prompt, ctx.capabilities?)   // текст
  → generate(prompt, { tools, signal }) // wire
```

Agentic loop (tool call → re-compose): compose **внутри** loop, когда `modelId` уже известен — отдельный режим pipeline, не v1.

### Расширения (additive)

- `TurnCapabilities` type + planner step или поля в `TurnRequest` / `ComposeInput`
- `PromptContext.capabilities` — read-only; resolver'ы как `addressingTelegramGroupResolver` (omit by flag)
- `LlmGenerateOptions.tools` — [#22](https://github.com/skepsik/utlas-ts/issues/22) adapter surface
- `llm_model_routes.supports_tools` (или capability flags) — strategy narrowing; см. [llm-execution-policy](./llm-execution-policy.md) policy/strategy hub

### Явных переделок не требуется

- Resolver chain, `PromptShared`, injectable deps — остаются
- Меняется **что передаётся в compose** и **что в generate**, не форма composer factory
- v0 path `enrich → compose → generate` — добавить **plan** перед compose; monolith `runTurn` → orchestrator step (north star ниже)

### Out of scope v1 (как было)

- Tool calls / HITL pause в hot loop — отдельный work после planner + structured `answer` step

---

## Open

- [ ] Runner zones vs плоский YAML list
- [ ] Structured output schema для `answer` / `should_reply`
- [ ] TurnStateStore API
- [ ] Где audit `llm_calls` (внутри llm step vs post-stop)
- [ ] Work breakdown: validator → runner skeleton → default scenario → transport adapter

---
