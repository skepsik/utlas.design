# LLM execution: strategy и policy

Два разных понятия на одной странице.

| Понятие | Статус |
|---------|--------|
| **Execution strategy** | **Есть:** PG + router, env `DEFAULT_EXECUTION_STRATEGY` |
| **Execution policy** (retry/backoff **одного step**) | **Пока нет:** одни константы в коде на все steps; целевая модель — ниже |

Несколько named strategies (answer, local inference) — [llm-jobs](./llm-jobs.md) (концепт).

---

## Execution strategy

Named ordered ladder: *какие* endpoint/model пробовать и *в каком порядке* при fail узла.

```text
strategy "default"
  [0] gemini-3.1-flash-lite
  [1] gemini-3-flash-preview
```

- PG: `llm_execution_strategies`, `llm_execution_strategy_steps`
- Router: flat cascade — next step on `LlmUnavailableError` ([#22](https://github.com/skepsik/utlas-ts/issues/22))
- Strategy **не** задаёт retry-числа (это зона policy, когда появится)

---

## Execution policy (целевая модель, не в коде)

Правила исполнения **одного узла** (step): retry, backoff, retryable errors, когда сдаться и отдать cascade следующему step. **Привязка к step**, не к strategy name.

```text
strategy "default"
  [0] route=gemini-flash-lite     policy=standard_retry   ← целевой вид
  [1] route=gemini-flash-preview  policy=quick_fail
```

Policy переиспользуется между steps и strategies. Strategy-level лимиты (deadline cascade, max steps, budget) — optional, later.

**Грань:** strategy = *чем и куда*; policy = *как упорствовать на текущем узле*.

### Целевая PG (TBD)

Таблица `llm_execution_policies` + FK `policy_id` на `llm_execution_strategy_steps`. Router читает retry из **step.policy**, не из global constants.

---

## Как сейчас в коде

| Concern | Где |
|--------|-----|
| Ordered model ladder | PG `llm_execution_strategy_steps` |
| Inner retry/backoff | `llm/policy.ts` — **одинаково на все steps** (это не execution policy в PG-смысле) |
| Outer cascade | `llm/router/router.ts` |
| Abort (no cascade) | `AbortError`, non-retryable 4xx |

Диаграммы выше с `policy=standard_retry` — **целевой** вид; в PG колонки policy пока нет.

---

## Инварианты (не менять без ADR)

- Strategy не дублирует retry-числа — только ссылка на policy (когда появится)
- Policy не задаёт порядок моделей
- Adapter — исполнитель: `retryMaxAttempts` / `retryBackoffMs` в factory input
- `llm/` не импортирует runtime storage — port + wiring в composition root

---

## Later

- PG `llm_execution_policies` + FK на steps ([#22](https://github.com/skepsik/utlas-ts/issues/22))
- per-chat / per-tenant strategy override
- per-model temperature / max_tokens
- prompt compose policy (omit/fatal) — [turn-prompt](./turn-prompt.md), не путать с execution policy

---

## Open

- Детали schema sketch vs router — при реализации policy в PG ([#22](https://github.com/skepsik/utlas-ts/issues/22))
