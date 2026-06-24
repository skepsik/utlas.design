# LLM jobs (концепт)

Один каркас для **разных LLM-задач**: answer пользователю, внутренний inference в compose, позже — tools / orchestrator. Не дублировать пайплайн; менять **именованные профили** (prompt + strategy + parse).

См. также: [turn-prompt](./turn-prompt.md), [llm-execution](./llm-execution.md), [envelope](./envelope/index.md).

---

## Сейчас vs цель

**Сейчас** — один контур:

```text
compose(answer resolvers) → cascade(answer strategy) → parseLlmAnswer → deliver
```

**Цель** — тот же каркас, несколько **job**:

- **answer** — structured output, `LlmAnswer`, egress;
- **inference** — короткие задачи в compose (gates, классификация), в т.ч. локальная модель;
- общие кирпичи: composer, execution strategy, adapters, cascade.

**Enrichment** ([turn-pipeline](./turn-pipeline.md)) — отдельный слот до compose; inference-job может жить **внутри** resolvers во время compose.

---

## LlmJob (концепт)

Именованная задача = тройка:

| Часть | Смысл |
|-------|--------|
| **prompt profile** | Своя цепочка resolvers + PG blocks |
| **execution strategy** | Named ladder в PG ([llm-execution](./llm-execution.md)) |
| **parse** | Что извлечь из raw после generate |

```text
runLlmJob(job, ctx)
  → compose(profile)
  → generate(strategy)    // cascade внутри
  → parse(raw)
```

Примеры (имена TBD):

| Job | Profile | Strategy | Parse |
|-----|---------|----------|-------|
| `answer` | полный turn | `default` | `LlmAnswer` |
| `block-pick` | короткий inference | `local-*` | свой контракт |

---

## Answer vs inference

| | **answer** | **inference** |
|---|------------|----------------|
| Когда | один раз на turn, после enrich | 0..N раз из resolvers при compose |
| Промпт | полный envelope | короткий, свой profile |
| Wire | structured output в адаптере | часто без schema; форма — зона адаптера |
| Результат | deliver, declare apply | gate / вход другому resolver |

**Инвариант:** шаги одной **answer**-strategy — взаимозаменяемые (structured, один agnostic prompt). Structured + plain на одной strategy — не целевой дизайн.

---

## Strategy ↔ prompt

Связь **именованная**, не через победителя cascade:

- Cascade failure-driven (429/503) — кто ответит, неизвестно до запроса.
- Job задаёт пару: profile + strategy (`answer` → `answer` + `default`).
- Fallback в strategy — между **совместимыми** шагами, **один** prompt profile.

---

## Промпт answer: форма vs policy

Три слоя (см. [turn-prompt](./turn-prompt.md)):

```text
envelope       — JSON object, camelCase, без fences
policy         — когда/как заполнять поля (PG + conditional resolvers)
wire shape     — responseSchema в адаптере (zod → vendor normalize)
```

Голую структуру объекта в system **не** дублировать, пока все шаги answer-strategy со structured output. Семантика — в policy.

Inference без structured output: адаптер может доклеить sketch формы в начало/конец system; composer провайдера не знает.

---

## Локальная модель

Отдельная job: свой profile, своя execution strategy (localhost / Ollama-совместимый endpoint), свой parse. Не `LlmAnswer`, не answer-cascade.

Вызов из resolver — через общий `runLlmJob`, не ad-hoc HTTP в каждом resolver.

---

## Кеш

- Compose pass: `once()` на thread/settings/blocks — достаточно для одного answer-compose.
- Inference в resolvers: при повторе за turn нужен **turn-scoped** cache (дорогой domain / LLM в resolver).
- Agnostic answer prompt — чтобы fallback по cascade не требовал второго compose.

---

## Later

- Несколько named strategies (answer, local inference) в PG.
- Первые inference jobs (conditional blocks, …).
- Turn-scoped cache для inference.
- per-tenant override job/strategy.

---

## Rejected

- **Подъём cascade выше compose** (re-compose на fallback): дорого (PG + domain + inference в resolvers), дрейф промпта за turn, усложнение логов; несовместимые провайдеры на одной strategy не планируем.
- Ad-hoc HTTP к local model в каждом resolver без composer/router.
- Дублировать answer envelope в inference jobs.
