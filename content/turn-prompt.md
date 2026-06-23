# Turn prompt

**Design hub для turn prompt** — не только «модульные блоки в PG», а весь контур: **что** модель видит (envelope + voice), **как** собирается `LlmPrompt`, **куда** расширять.

**Work shipped:** prompt composer v0 — feat-24 (ветка `feat-24`, work [#24](https://github.com/skepsik/utlas-ts/issues/24) closed).

---

## Контент (prod reference)

Python `ai-bot/prompts/` — reference до cutover. TS seed: `prompts/system_prompt_{private,group}.txt`.

### Роли блоков user envelope

| Блок | Domain | Смысл для модели |
|------|--------|------------------|
| **CHAT HISTORY** | `RecentMessages` | Хронологический хвост перед anchor; фон, не центр turn |
| **SEMANTIC THREAD** | `SemanticThread` | Семантическая нить вокруг anchor — **приоритетный** контекст vs history |
| **USER MESSAGE** | anchor + `queryText` | Центр текущего turn |

**Порядок в user:** `CHAT HISTORY` → `SEMANTIC THREAD` → `USER MESSAGE` (зафиксировано в коде и тестах).

### System voice (Zera)

- **Private:** «Zera в личном чате» — turn = последнее обращение; history для контекста.
- **Group:** «участник группового чата» — явный сигнал (@, reply, /ask); чужие реплики могут быть в history; burst одной мысли.
- Общие секции §1–§6: constraints, style, length, frame handling, content strategy, prohibitions.
- **Meta-visibility:** group overclaim — [#20](https://github.com/skepsik/utlas-ts/issues/20) (backlog content).

### Форматирование сообщений

- `[quote]` / `[end quote]` — partial quote + комментарий автора.
- `[forward from: …]` — реpost; дата origin, не пересылки.
- Timestamps UTC `YYYY-MM-DD HH:mm:ss`, sender `@handle`.

---

## Архитектура assembly (as implemented)

### PG

```text
prompt_blocks (id serial PK, name text UNIQUE, text text NOT NULL)
```

- Seed: monolithic `system_prompt_*.txt` → rows **as-is** (без рерайта).
- Редактирование текста — в БД; **новая секция** = resolver + место в массиве (git), не manifest в PG.

### Composer (`llm/prompt/`)

```text
createPromptComposer(deps)   // main.ts
compose(input)               // один pass на LLM-вызов
  → pass-scoped PromptShared (once / Map для loadBlock)
  → build(systemResolvers, ctx) + build(userResolvers, ctx)
  → { system, user }
```

- Resolvers = legacy envelope + system block из PG
- `TurnServices.promptComposer`; `runTurn` → `compose()`
- Parity: `test/prompt-composer.test.ts`

### PromptShared (pass-scoped)

- `getRecent` / `getSettings` / `getThread` — `once()`; **один** `getSettings` переиспользуется в `getRecent`.
- `loadBlock(name)` — `Map<name, Promise<string>>` per pass.
- **Расширение:** новый derived input → новый getter с `once()` на `PromptShared` (один владелец на ключ).

### Resolvers

- Plain `(ctx) => string | null`; массивы `systemResolvers` / `userResolvers`.
- Deps — только `await ctx.shared.getX()`.
- Errors: default — log + omit section; `PromptComposeFatalError` → rethrow (`compose` abort). System block + policy — fatal; user envelope — best-effort omit.

---

## Отклонено: contributors / signals / merge

В первой итерации feat-24 был слой `Contributor → Partial<signals> → mergeSignalPatches → ctx.signals`. **Убран** — overengineering под несуществующий кейс.

**Почему:**

- Дедуп fetch — уже `once()` / `loadBlock` Map на `PromptShared`.
- Несколько независимых derived keys — **точечные `once()` getters** на `PromptShared`, без patch-merge.
- Footgun: `{ key: undefined }` + `if (value === undefined) continue` тихо ломает collision throw; `Object.keys` vs omit — скользкая семантика.
- Enrichment уже eager и отдельно в `turn/`; dynamic plugin registry — отдельная история, не signals.

**Если понадобится dynamic registry writer'ов** (как `EnrichmentRegistry`) — проектировать заново под конкретный кейс, не восстанавливать merge-as-is.

---

## Later (не в v0)

| Тема | Сейчас | Later |
|------|--------|-------|
| **Derived inputs** | getters на `PromptShared` | новый `once()` getter |
| **Manifest / order in PG** | resolver arrays in git | user-editable order — out |
| **TurnHints, inference, regen** | — | [turn-pipeline](./turn-pipeline.md) |
| **Retrieval envelope/budget** | stub `retrieval/envelope.ts` | trim/rank blocks |
| **Shared context bus** | — | [context-bus](./context-bus.md) |
| **Enrichment → prompt** | fragments не в compose | [turn-pipeline](./turn-pipeline.md) |
| **Tools / model capabilities** | composer без model; transport via anchor | planner + `TurnCapabilities` — [turn-pipeline](./turn-pipeline.md) § Later |

---

## Open

- [ ] Content: group overclaim guard ([#20](https://github.com/skepsik/utlas-ts/issues/20))
- [ ] Semantic thread selectors beyond `replyChain` ([domain](./domain.md) § Open)
- [ ] Deprecate file `prompt-loader` после стабилизации PG seed в prod
- [x] Resolver error policy v0 — `PromptComposeFatalError` in `buildSection`
- [ ] Enrichment fragments в prompt path ([turn-pipeline](./turn-pipeline.md))
