# Turn pipeline

**Turn / pipeline** — скобка конкурентности (`turn.start` / `turn.stop`), сценарий шагов orchestrator'а и default path user→bot. Transport ([transport](./transport/)) вызывает `runTurn`; domain ([domain](./domain/)) agnostic.

См. также: [envelope](./envelope/index.md), [turn-prompt](./turn-prompt.md), [llm-jobs](./llm-jobs.md).

---

## Зачем

В v0 invoke, parse, deliver и скобка конкурентности слиты в `runTurn`. Burst реализован через `cancelGenerationTask` + `shouldDiscardOnSend` — **stop** фактически привязан к send, не к завершению read/LLM. Нужна явная скобка и граф шагов: всё read/LLM внутри `turn.start` … `turn.stop`, все write после stop.

---

## Термины

| Термин | Смысл |
|--------|--------|
| **Turn** | только **`turn.start` / `turn.stop`** — скобка конкурентности (supersede, in-flight) |
| **Pipeline** | сценарий шагов orchestrator'а; **0..N** turn-скобок в теории, **v1: 0 или 1** |
| **Ingress** | опциональный шаг: событие → anchor (+ persist). Transport может делать до runner |
| **Deliver** | опциональный шаг: отправка в мессенджer (egress-**шаг**, не скобка turn) |

**Не путать:** ingress / deliver — **шаги pipeline**, не синонимы `turn.start` / `turn.stop`.

---

## Сейчас vs цель

**Сейчас (v0)** — monolith `runTurn` в `apps/runtime/src/turn/run-turn.ts` + in-memory supersede в `turn-state.ts`:

```text
transport: persistIngress → qualifiesForTurn? → runTurn(TurnRequest)
runTurn:
  bot_enabled → onNewTurnMessage (supersede?) → GenerationTask → runGeneration
  enrichTurn → promptComposer.compose → llmProvider.generate → tool loop?
  → applyConversationSettings?
  → if shouldReply: outbound.deliver(text, history)
  → debug silent: sendEphemeralEgress(DEBUG_SILENT)
  fail generation → handleGenerationFailure (PG + ephemeral по политике)
  shouldDiscardOnSend → clearActiveAfterSend   ← stop при send, не после LLM
```

Failure routing — [transport](./transport/) § Generation failures ([#76](https://github.com/skepsik/utlas-ts/issues/76)).

| Аспект | Сейчас (v0) | Цель |
|--------|-------------|------|
| Скобка | неявная, до send | `turn.start` … `turn.stop` |
| Deliver | `if shouldReply` в monolith (debug: silent notice) | явный шаг `deliver` в графе, та же семантика |
| Burst | cancel task + discard send | re-enter pipeline с `turn.start` |
| State | module-global `Map` в `turn-state.ts`, `getTurnState` без DI | injectable **TurnStateStore** |
| Orchestrator | stubs (`loader`, `runner`, `StepRegistry`) | validator → runner → default scenario |

**`/ask`:** **ingress есть** (`persistIngress` + `TurnRequest.textOverride`), отличие — только **нет** `qualifiesForTurn`; отдельного pipeline не нужно.

**Цель** — YAML-сценарий ниже; implementation — work issues (§ **Цель**).

---

## Целевой default pipeline

Один граф для всех user-message path (включая «будильник, молчи»):

```yaml
- ingress: {}              # или transport до runner
- turn.start: {}

- build_context: {}
- llm:
    slot: answer             # structured: shouldReply + content + …

- turn.stop: {}             # явный шаг сценария, не автоматика в llm/

- connector: {}             # 0..N, post-turn
- deliver:
    if: shouldReply         # false → no-op
```

Формат `LlmAnswer` — [envelope](./envelope/index.md#answer-envelope-canonical). `shouldReply: false` → deliver no-op.

**Порядок:** `turn.stop` **до** `deliver`. **Post-turn write** (deliver, connector, audit) только после нормального stop.

---

## Burst и `turn.start`

`turn.start` = начало **тела итерации**, не «включи supersede навсегда».

```text
новое qualifying сообщение (в gap)
  → abort in-flight (AbortSignal)
  → re-enter pipeline с turn.start
  → … read / llm …
  → turn.stop
  → post-turn (если !aborted)
```

YAML: `turn.start` / `turn.stop` **один раз в файле**; runner **переисполняет** тело на каждый burst / ingress.

---

## Инвариант: read + LLM внутри скобки

Между `turn.start` и `turn.stop` **только read и LLM** (cancellation-safe):

| Разрешено | Запрещено |
|-----------|-----------|
| `MessageReadPort`, load context / graph | connector write |
| `build_context`, enrichment read-only | thread.append / persist graph |
| `llm.generate` (+ `AbortSignal`) | `OutboundPort.deliver` (post-turn) |

Ingress (persist входящего) — **до** `turn.start`.  
**Все write** (connector, deliver, audit batch, materialize thread) — **после** `turn.stop`.

Enforce: step kind + YAML validator + runner zones.

---

## Abort

**Каждый** orchestrator step получает `AbortSignal` (не только turn).

При abort:

```text
turn.start
try:   read* → llm*
       turn.stop          # нормальный сценарий без abort — закрытие итерации
catch AbortError:
finally:
       turn.stop()        # только если start был и stop ещё нет
# post-turn — НЕ выполнять если aborted
```

|                                                    | Нормальный сценарий без abort                    | Abort                                                                     |
| -------------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------- |
| **`turn.stop` в try**                              | явный шаг pipeline; после него — post-turn write | не достигнут                                                              |
| **`turn.stop` в `finally`**                        | —                                                | **только** снять supersede-scope; **не** write, **не** «догнать pipeline» |
| **Post-turn write** (deliver, connector, audit, …) | после try-stop                                   | **не запускаются**                                                        |

`finally`-stop ≠  happy-path stop ≠ разрешение на deliver. Runner: pre-turn → turn body → turn close → **post-turn iff !aborted**.

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

- `turn-state.ts` — module-global `Map<UserKey, UserTurnState>`, `getTurnState` без DI → injectable **TurnStateStore**
- `runTurn` monolith → `orchestrator/runner` + steps

---

## Capabilities и tools (цель, не v0)

Когда появятся tools (`toolCalls` в structured answer), часть strategy (модели без надёжного JSON schema) отпадает для tool-turn'ов. Native API tools и multi-message wire — [Rejected](./tools/native-tool-calls.md). Это **не переделка composer** — расширение turn + llm контуров.

### Границы ответственности

| Слой | Роль |
|------|------|
| **Turn planner** (`turn/` или step `build_context`) | Snapshot на turn: `transport × model × connectors` → `TurnCapabilities` |
| **Strategy / router** | Steps с `supports_tools`; filter или отдельная **именованная стратегия** для tool-turn |
| **Composer** ([turn-prompt](./turn-prompt.md)) | **Consumer** snapshot: optional текст в prompt; omit tool-blocks если `!supportsTools`. **Не** source of truth для tool list |
| **Adapter / `LlmProvider.generate`** | Wire: `responseSchema` на весь `LlmAnswer` incl. `toolCalls?`; tools list — prompt ([tools](./tools/index.md) § Prompt), не native `tools` / `toolChoice` |

```text
availableTools = transportActions(transport)
               ∩ modelCapabilities(model|route)
               ∩ enabledClients
```

### Порядок (цель, не ломает v0 composer)

```text
plan capabilities (transport + intended tools + strategy filter)
  → compose(prompt, ctx.capabilities?)
  → generate(prompt, { signal })   // structured answer incl. toolCalls
```

Agentic loop (tool call → re-compose): compose **внутри** loop, когда `modelId` уже известен — отдельный режим pipeline, не v1.

### Расширения (additive)

- `TurnCapabilities` type + planner step или поля в `TurnRequest` / `ComposeInput`
- `PromptContext.capabilities` — read-only; resolver'ы как `addressingTelegramGroupResolver` (omit by flag)
- `LlmGenerateOptions` — без native `tools` ([#22](https://github.com/skepsik/utlas-ts/issues/22)); см. [native-tool-calls](./tools/native-tool-calls.md)
- `llm_model_routes.supports_tools` (или capability flags) — strategy narrowing; см. [llm-execution](./llm-execution.md)

### Явных переделок не требуется

- Resolver chain, `PromptShared`, injectable deps — остаются
- Меняется **что передаётся в compose** и **что в generate**, не форма composer factory
- v0 path `enrich → compose → generate` — добавить **plan** перед compose; monolith `runTurn` → orchestrator step

Tool calls / **HITL pause** в **hot loop** — отдельный work после planner + structured `answer` step (не v1).

---

## Out of scope

- **N > 1** turn-скобок в одном pipeline run (теория 0..N; **практика v1: 0 или 1**). Clarification loop / HITL — отдельные ingress → отдельные runs, не два turn в одном YAML
- Tool calls / HITL pause в **hot loop** (до planner + answer step)
- Persisted thread graph, decision graph (git-like commits)
- Расследование тишины на «привет, молчи» в prod (логи отдельно)

---

## Later

- Materialized semantic graph, post-stop append
- Parallel tool executor — [tools](./tools/index.md)

---

## Открытые вопросы

- Runner zones vs плоский YAML list
- Structured output schema — [envelope](./envelope/index.md)
- TurnStateStore API
- Где audit `llm_calls` — внутри llm step vs post-stop

---

## Цель

- Orchestrator skeleton: validator → runner → default scenario → transport adapter
- Explicit `turn.start` / `turn.stop` вместо stop-on-send (см. **Rejected**)

---

## Rejected

### Stop привязан к send

Текущий v0-паттерн `shouldDiscardOnSend` → `clearActiveAfterSend` (**не сохраняем**): stop должен быть явным шагом pipeline **до** deliver, иначе abort при send оставляет скобку открытой и post-turn семантику не видно в графе.
