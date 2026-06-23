# LLM execution policy

**Execution strategy** — named ordered ladder узлов: *какие* endpoint/model пробовать и *в каком порядке* при fail узла. Env `DEFAULT_EXECUTION_STRATEGY` → `llm_execution_strategies.name`.

**Execution policy** — правила исполнения **одного узла** (step): retry, backoff, timeout, retryable errors, момент перехода к следующему узлу cascade. **Привязка к узлу, не к strategy.** Policy переиспользуется между steps и strategies.

Strategy-level policy — только сквозные ограничения (deadline cascade, max steps, budget); optional, later.

```
strategy "default"
  [0] route=gemini-flash-lite    policy=standard_retry
  [1] route=gemini-flash-preview policy=quick_fail
```

Грань: **strategy = чем и куда; policy = как упорствовать на текущем узле.** Не «где лежит в коде» — оба могут быть в PG; сейчас policy одна в коде как временная стадия.

---

## Как сейчас

| Concern | Где |
|--------|-----|
| Ordered model ladder | PG `llm_execution_strategy_steps` |
| Inner retry/backoff | `llm/policy.ts` — одинаково на все steps |
| Outer cascade | `llm/router/router.ts` — next step on `LlmUnavailableError` |
| Abort (no cascade) | `AbortError`, non-retryable 4xx |

---

## Целевая модель (PG)

### `llm_execution_policies` (name TBD)

| column | notes |
|--------|-------|
| name | UNIQUE, e.g. `standard_retry`, `quick_fail` |
| retry_max_attempts | int |
| retry_backoff_ms | json/int[] или text (parse) |
| retryable_http_codes | int[] default `{429,503}` |

Step FK:

```text
llm_execution_strategy_steps
  + policy_id FK → llm_execution_policies (NOT NULL, default seed row)
```

Read path: `ExecutionStrategyStep` DTO + `policy: { retryMaxAttempts, retryBackoffMs, … }`.

Router: `createStepAdapter(step)` — retry из **step.policy**, не global constants.

### Strategy-level (later, optional)

- `llm_execution_strategies.default_policy_id` — fallback для steps без override
- `cascade_deadline_ms`, `max_cascade_steps`

---

## Инварианты (не менять без ADR)

- **Strategy** не дублирует retry-числа — только ссылка на policy
- **Policy** не задаёт порядок моделей
- Adapter — тупой исполнитель: `retryMaxAttempts` / `retryBackoffMs` в factory input; источник — step DTO
- `llm/` не импортирует `@/storage` — port + wiring в `main.ts`

---

## Out of scope

- [ ] per-chat / per-tenant strategy override
- [ ] admin UI / CRUD policies
- [ ] per-model temperature / max_tokens (отдельный design)
- [ ] prompt compose policy (omit/fatal) — [turn-prompt](./turn-prompt.md)

---

## Work breakdown (implement)

1. Canonical design (this page)
2. Migration + seed `standard_retry` (= current constants)
3. FK `policy_id` on steps; backfill → `standard_retry`
4. DTO + read port; router reads per-step policy
5. Thin `llm/policy.ts` → error taxonomy only (`isUnavailableError`, shared retryable codes)
6. Second policy in seed (`quick_fail`) + step assignment demo

---

## Acceptance (design)

- [ ] Грань strategy vs policy согласована
- [ ] Policy = per-node; strategy = ordered nodes + optional global budget
- [ ] Schema sketch не ломает port boundaries router (#22)

---
