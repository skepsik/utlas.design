# LLM jobs (концепт)

Один **транспортный** каркас для разных вызовов LLM: answer, inference в compose, позже orchestrator. Менять **именованные профили** (prompt + strategy), не копировать compose/cascade.

См. также: [turn-prompt](./turn-prompt.md), [llm-execution](./llm-execution.md), [envelope](./envelope/index.md).

---

## Две фазы (граница)

**LLM execution** — только доставить сырой ответ модели:

```text
compose(profile) → generate(strategy) → raw (+ routeLabel)
```

**Business flow** — смысл raw; живёт у **вызывающего**, не в общем LLM-каркасе:

```text
raw → parse → apply / tool loop / deliver / gate …
```

| Слой | Входит | Не входит |
|------|--------|-----------|
| LLM invoke | profile, strategy, cascade, adapter wire schema | `parseLlmAnswer`, declare apply, deliver, tools |
| Answer turn | вызывает invoke, потом свой pipeline | — |
| Inference resolver | вызывает invoke, потом свой маленький parse | deliver, `LlmAnswer` |

---

## Сейчас vs цель

**Сейчас** — invoke и business слиты в `runTurn`:

```text
compose → cascade → parseLlmAnswer → applyConversationSettings → deliver
```

**Цель** — явный **invoke** + несколько profile/strategy пар; business остаётся у call site.

- **answer** — profile полного turn, strategy `default`; после raw — [envelope](./envelope/index.md) parse + turn apply + deliver.
- **inference** — короткий profile, своя strategy (в т.ч. local); после raw — узкий parse (gate, labels).

**Enrichment** ([turn-pipeline](./turn-pipeline.md)) — до compose answer; inference-invoke может жить **внутри** resolvers.

---

## Llm invoke (концепт)

Именованный вызов = пара:

| Часть | Смысл |
|-------|--------|
| **prompt profile** | Цепочка resolvers + PG blocks |
| **execution strategy** | Ladder в PG ([llm-execution](./llm-execution.md)) |

```text
llmInvoke({ profile, strategy, ctx }) → { raw, routeLabel }
```

Примеры (имена TBD):

| Call site | Profile | Strategy | После `raw` (call site) |
|-----------|---------|----------|-------------------------|
| answer `runTurn` | `answer` | `default` | `parseLlmAnswer`, declare apply, deliver |
| resolver gate | `inference.block-pick` | `local-*` | свой zod / text → bool |

---

## Answer vs inference

| | **answer** | **inference** |
|---|------------|----------------|
| Когда | один invoke на turn | 0..N invoke из resolvers при compose |
| Profile | полный turn envelope | короткий |
| Wire | structured output в адаптере | часто без schema |
| После raw | full turn business | только то, что нужно resolver |

**Инвариант:** шаги одной answer-strategy — взаимозаменяемые (structured, один agnostic prompt).

---

## Strategy ↔ prompt

Именованная пара profile + strategy; не через победителя cascade (failure-driven, 429/503). Fallback — совместимые шаги, **один** profile.

---

## Промпт answer: форма vs policy

Три слоя ([turn-prompt](./turn-prompt.md)):

```text
envelope       — JSON object, camelCase
policy         — PG + conditional resolvers
wire shape     — responseSchema в адаптере
```

Голую структуру в system не дублировать при structured output. Inference без schema — sketch в адаптере (start/end system).

---

## Локальная модель

Отдельная **strategy** + короткий **profile**; invoke как у облака. Parse и смысл — только у resolver, не `LlmAnswer`.

---

## Кеш

- `once()` на compose pass — OK для одного answer-compose.
- Inference в resolvers — **turn-scoped** cache при повторе.
- Agnostic answer profile — без re-compose на cascade fallback.

---

## Later

- Явный `llmInvoke` в коде (отделить от `parseLlmAnswer`).
- Named strategies в PG (answer, local inference).
- Turn-scoped cache для inference.

---

## Rejected

- **Подъём cascade выше compose** (re-compose на fallback): дорого (PG + domain + inference в resolvers), дрейф промпта за turn, усложнение логов; несовместимые провайдеры на одной strategy не планируем.

- **Единый RPC `runJob(profile, strategy) → TypedResult`** — parse, apply, tool loop, deliver внутри общего LLM-каркаса:
  - **Разные выходы:** answer → `LlmAnswer` + declare; inference → bool / labels / короткий JSON. Один typed facade = union на все сценарии или generics через весь стек; каждый новый call site тянет общий контракт.
  - **Side effects не симметричны:** deliver и declare apply — только answer-turn; tool loop — только answer; inference в resolver — ни того ни другого. Смешивать в одном «job» — склеить transport с доменом `runTurn`.
  - **Registry с флагами** (`parse?`, `apply?`, `deliver?`) — тот же раздутый контракт, только спрятанный; усложняет тесты и observability (что именно сделал вызов).
  - **Слой уже слипся** (`parseLlmAnswer` в router) — цель явно **развести**, а не оформить монолитом. Общее только invoke → `raw`; после `raw` владелец сценария (`runTurn`, конкретный resolver).
  - **Допустимо точечно:** узкий API call site (`classifyFollowup(ctx): boolean` внутри сам зовёт invoke + parse) — не универсальный LLM-job.

- Ad-hoc HTTP к local model в resolver без composer/router.

- Дублировать answer envelope в inference profiles.
