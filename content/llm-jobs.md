# LLM jobs (концепт)

Один **транспортный** каркас для разных вызовов LLM: answer, inference в **compose**, позже orchestrator. Меняем **именованные profile + strategy** ([llm-execution](./llm-execution.md)), не копируем **compose**/**cascade** под каждый сценарий.

См. также: [turn-prompt](./turn-prompt.md), [envelope](./envelope/index.md).

**Статус:** концепт; `llmInvoke` в коде пока нет — answer-path слит в `runTurn` + `createLlmRouter`.

---

## Зачем

Сейчас invoke и **обработка после LLM** живут в одном месте: `runTurn` → `promptComposer.compose` → `llmProvider.generate` → уже распарсенный `LlmAnswer` → `applyConversationSettings` → deliver. При inference в resolvers (SemanticThread builder, gate, labels) тот же зазор пришлось бы копировать или размывать границы.

Нужна явная граница: каркас доставляет **raw**; смысл **raw** — у **вызывающего кода** (answer-turn, конкретный resolver).

---

## Две фазы

**LLM execution** — только доставить сырой ответ модели:

```text
compose(profile) → generate(strategy) → raw (+ routeLabel)
```

**Обработка после LLM** — parse, apply, **tool loop**, deliver, gate и т.д.; **не** входит в общий LLM-каркас:

```text
raw → parse → apply / tool loop / deliver / gate …
```

| Слой | Входит | Не входит |
|------|--------|-----------|
| LLM invoke (концепт) | profile, strategy, **cascade**, wire schema в adapter | `parseLlmAnswer`, declare apply, deliver, tools |
| Answer turn | invoke, потом свой pipeline | — |
| Inference resolver | invoke, потом узкий parse | deliver, полный `LlmAnswer` |

---

## Сейчас vs цель

**Сейчас (v0)** — монолит в `apps/runtime/src/turn/run-turn.ts`:

```text
enrichTurn → promptComposer.compose → llmProvider.generate → result.answer
  → applyConversationSettings → deliver / saveBotReply
```

`llmProvider` — `createLlmRouter` ([#22](https://github.com/skepsik/utlas-ts/issues/22)); внутри router уже вызывается `parseLlmAnswer` — coupling, см. [llm-execution](./llm-execution.md).

**Цель** — явный invoke (концепт `llmInvoke`) и несколько пар profile/strategy; **обработка после LLM** остаётся у **вызывающего кода**:

- **answer** — profile полного turn, strategy `default`; после `raw` — parse [envelope](./envelope/index.md), turn apply, deliver.
- **inference** — короткий profile, своя **именованная стратегия** (в т.ч. local); после `raw` — узкий parse (gate, labels).

**Enrichment** ([turn-pipeline](./turn-pipeline.md)) — до compose answer-profile; inference-invoke может жить **внутри** resolvers при compose.

---

## Invoke (концепт)

Именованный вызов = пара **prompt profile** + **execution strategy**:

| Часть | Смысл |
|-------|--------|
| **prompt profile** | Цепочка resolvers + PG `prompt_blocks` ([turn-prompt](./turn-prompt.md)) |
| **execution strategy** | Ladder в PG ([llm-execution](./llm-execution.md)) |

```text
llmInvoke({ profile, strategy, ctx }) → { raw, routeLabel }
```

Примеры (имена profile/strategy — **Открытые вопросы**):

| Вызывающий код | Profile | Strategy | После `raw` |
|----------------|---------|----------|-------------|
| answer `runTurn` | `answer` | `default` | `parseLlmAnswer`, declare apply, deliver |
| resolver gate | `inference.block-pick` | `local-*` | свой zod / text → bool |

---

## Answer vs inference

| | **answer** | **inference** |
|---|------------|----------------|
| Когда | один invoke на turn | 0..N invoke из resolvers при compose |
| Profile | полный turn envelope | короткий |
| Wire | **structured output** в adapter | часто без schema |
| После `raw` | полная обработка answer-turn | только то, что нужно resolver |

**Инвариант:** шаги одной answer-strategy взаимозаменяемы (**structured output**, один agnostic prompt) — re-compose на **cascade** fallback **не** делаем (§ Rejected ниже).

---

## Strategy ↔ prompt

Именованная пара profile + strategy; route не выбирается «победителем» в **вызывающем коде**. **Failure-driven fallback** — не у **вызывающего кода**, а в **cascade** router (429/503). **Fallback** — совместимые steps, **один** profile на весь **cascade**.

---

## Answer prompt: форма vs policy

Три слоя ([turn-prompt](./turn-prompt.md)):

```text
envelope   — JSON object, camelCase (policy в system)
policy     — PG + conditional resolvers
wire shape — responseSchema в adapter
```

Голую структуру объекта в system **не** дублировать при **structured output**. Inference без schema — sketch в adapter (start/end system).

---

## Local model

Отдельная **strategy** + короткий **profile**; invoke по тому же каркасу, что облако. Parse и смысл — только у resolver, не полный `LlmAnswer` / deliver.

---

## Кеширование

- `once()` на compose pass — нормально для одного answer-compose.
- Inference в resolvers — **turn-scoped** cache при повторном чтении в том же turn (механика — **Открытые вопросы**).
- Agnostic answer profile — **без** re-compose на **cascade** fallback (один profile на все steps strategy).

---

## Later

- Явный `llmInvoke` в коде — отделить от `parseLlmAnswer` в router
- **Именованные стратегии** в PG (answer, local inference) — см. [llm-execution](./llm-execution.md)
- **Turn-scoped** cache для inference

---

## Открытые вопросы

- Имена profile/strategy (`answer`, `inference.block-pick`, …) — TBD при work-issue
- **Turn-scoped** cache для inference — механика хранения и ключи

---

## Rejected

### Подъём cascade выше compose

Re-compose на fallback (**не делаем**): дорого (PG + domain + inference в resolvers), дрейф промпта за turn, усложнение логов; несовместимые провайдеры на одной strategy не планируем.

### Единый RPC `runJob(profile, strategy) → TypedResult`

Parse, apply, **tool loop**, deliver внутри общего LLM-каркаса (**не делаем**):

- **Разные выходы:** answer → `LlmAnswer` + declare; inference → bool / labels / короткий JSON. Один typed facade = union на все сценарии или generics через весь стек; каждый новый **вызывающий код** тянет общий контракт.
- **Side effects не симметричны:** deliver и declare apply — только answer-turn; **tool loop** — только answer; inference в resolver — ни того ни другого. Смешивать в одном «job» — склеить transport с доменом `runTurn`.
- **Registry с флагами** (`parse?`, `apply?`, `deliver?`) — тот же раздутый контракт, только спрятанный; усложняет тесты и observability.
- **Слой уже слипся** (`parseLlmAnswer` в `createLlmRouter`) — цель явно **развести**, а не оформить монолитом. Общее только invoke → `raw`; после `raw` — владелец сценария (`runTurn`, конкретный resolver).
- **Допустимо точечно:** узкий API (`classifyFollowup(ctx): boolean` сам зовёт invoke + parse) — не универсальный LLM-job.

### Ad-hoc HTTP к local model

В resolver без composer/router (**не делаем**): выпадает из **cascade**, логов, strategy.

### Дублировать answer envelope в inference profiles

(**Не делаем**): inference profile короткий, своя schema или без schema.
