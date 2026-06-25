# LLM execution: strategy и policy

**Execution strategy** — *какие* endpoint/model пробовать и *в каком порядке* при сбое узла.

**Execution policy** — *как упорствовать на текущем узле* (retry, backoff, retryable errors), без смены порядка ladder.

Несколько именованных стратегий (answer, local inference) — [llm-jobs](./llm-jobs.md) (концепт).

| Понятие | Статус |
|---------|--------|
| **Execution strategy** | **Есть:** PG + `createLlmRouter`, env `DEFAULT_EXECUTION_STRATEGY` |
| **Execution policy** (retry/backoff **одного step**) | **Пока нет в PG:** одни константы в `@utlas/core/llm/policy.ts` на все steps |

---

## Сейчас vs цель

| Concern              | Сейчас (v0)                                                                                                                        | Цель                    |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | ----------------------- |
| Ordered model ladder | PG `llm_execution_strategies`, `llm_execution_strategy_steps` → `llm_model_routes`                                                 | без изменений           |
| Inner retry/backoff  | `LLM_RETRY_MAX_ATTEMPTS`, `LLM_RETRY_BACKOFF_MS` в `policy.ts` — **одинаково на все steps**                                        | per-step policy из PG   |
| Outer **cascade**    | `createLlmRouter` в `router/router.ts` — next step on `LlmUnavailableError` ([#22](https://github.com/skepsik/utlas-ts/issues/22)) | без изменений           |
| Abort (no cascade)   | `AbortError`, non-retryable 4xx — пробрасываются, **cascade** не идёт                                                              | без изменений           |
| Parse answer         | `parseLlmAnswer` внутри router — см. [llm-jobs](./llm-jobs.md)                                                                     | развести invoke и parse |

Диаграммы ниже с `policy=standard_retry` — **цель**; колонки policy в PG пока нет.

---

## Execution strategy

Named ordered ladder steps: env `DEFAULT_EXECUTION_STRATEGY` → `llm_execution_strategies.name`.

```text
strategy "default"
  [0] gemini-3.1-flash-lite
  [1] gemini-3-flash-preview
```

**Сейчас в коде:**

- PG: `llm_execution_strategies`, `llm_execution_strategy_steps` (position + FK на `llm_model_routes`)
- Startup: `validateLlmRouterConfig` — fail-fast (strategy exists, steps ≥ 1, adapter known, api key present)
- Runtime: `buildLlmRouterSteps` → `createLlmRouter`; flat **cascade** по steps
- Strategy **не** задаёт retry-числа — это зона execution policy

**Failure-driven fallback** между steps — в router: после inner retry на step adapter бросает `LlmUnavailableError` (429/503), router пробует следующий step. Не выбор «победителя» route.

---

## Execution policy

Правила исполнения **одного узла** (step): retry, backoff, какие HTTP-коды retryable, когда сдаться и отдать **cascade** следующему step. **Привязка к step**, не к имени strategy.

```text
strategy "default"
  [0] route=gemini-flash-lite     policy=standard_retry   ← цель
  [1] route=gemini-flash-preview  policy=quick_fail
```

Policy переиспользуется между steps и strategies. Strategy-level лимиты (deadline **cascade**, max steps, budget) — optional, **Later**.

**Грань:** strategy = *чем и куда*; policy = *как упорствовать на текущем узле*. Оба могут жить в PG; **сейчас** policy одна в коде как временная стадия.

### Inner retry vs outer cascade

| Уровень | Где | Что делает |
|---------|-----|------------|
| **Inner** (execution policy) | adapter factory (`createStepAdapter`) | retry на **том же** step: `retryMaxAttempts`, `retryBackoffMs` из `policy.ts` |
| **Outer** (strategy) | `createLlmRouter` | следующий step после `LlmUnavailableError` |

**Сейчас:** inner — константы `LLM_RETRY_MAX_ATTEMPTS = 3`, `LLM_RETRY_BACKOFF_MS = [1000, 2000]` для каждого adapter. Outer — цикл по `LlmRouterStepRunner[]`.

### Целевая PG (TBD, [#22](https://github.com/skepsik/utlas-ts/issues/22))

Таблица `llm_execution_policies` (имена вроде `standard_retry`, `quick_fail`):

| column | notes |
|--------|-------|
| name | UNIQUE |
| retry_max_attempts | int |
| retry_backoff_ms | json/int[] или text |
| retryable_http_codes | int[] default `{429,503}` |

FK `policy_id` на `llm_execution_strategy_steps`. Read path: `ExecutionStrategyStep` DTO + вложенный `policy`. `createStepAdapter(step)` берёт retry из **step.policy**, не из global constants.

---

## Инварианты (не менять без ADR)

- Strategy не дублирует retry-числа — только ссылка на policy (когда появится)
- Policy не задаёт порядок моделей
- Adapter — исполнитель: `retryMaxAttempts` / `retryBackoffMs` в factory input; источник — step DTO
- `llm/` не импортирует runtime storage — port + wiring в composition root (`main.ts`)

---

## Цель

Work [#22](https://github.com/skepsik/utlas-ts/issues/22):

- Migration + seed `standard_retry` (= текущие константы)
- FK `policy_id` on steps; backfill → `standard_retry`
- DTO + read port; router читает per-step policy
- Thin `llm/policy.ts` → error taxonomy (`isUnavailableError`, shared retryable codes)
- Second policy в seed (`quick_fail`) + demo назначения на step

---

## Открытые вопросы

- Детали schema sketch vs router — при реализации policy в PG ([#22](https://github.com/skepsik/utlas-ts/issues/22))

---

## Later

- per-chat / per-tenant strategy override
- per-model temperature / max_tokens
- Strategy-level: `cascade_deadline_ms`, `max_cascade_steps`, optional `default_policy_id` на strategy
- prompt compose policy (omit/fatal) — [turn-prompt](./turn-prompt.md); **не путать** с execution policy

---

## Out of scope

- admin UI / CRUD policies
- prompt compose policy как часть этой страницы — живёт в [turn-prompt](./turn-prompt.md)
