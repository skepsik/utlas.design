# Turn prompt

Сборка `LlmPrompt` для turn: **composer** в `@utlas/core/llm/prompt/`; default resolver chains — `apps/runtime/src/llm/`. Текст policy — в PG `prompt_blocks`; **порядок секций — только в git** (`prompt-composer.ts` + тесты). Вики — роли и паттерны, не нумерованный manifest.

Domain slots — [domain](./domain.md) § Context assembly.

---

## Composer

```text
createPromptComposer({ deps, systemResolvers?, userResolvers? })
compose(ComposeInput) → { system, user }
```

`ComposeInput`: `anchor`, `arity` (`private` | `group`), `queryText`, `transport`.

Wiring: `TurnServices.promptComposer` → `runTurn` вызывает `compose()` перед LLM.

### Один pass

1. `PromptShared` — pass-scoped memo (`once()` для `getRecent`, `getThread`, `getSettings`; `loadBlock` — Map per key).
2. `PromptContext` — `anchor`, `arity`, `queryText`, `transport`, `shared`.
3. `buildSection(systemResolvers)` и `buildSection(userResolvers)` параллельно.
4. Секции склеиваются через `\n\n`.

---

## System chain (answer profile)

**Порядок — только в коде:** `apps/runtime/src/llm/prompt-composer.ts` (`systemResolvers`). Тесты фиксируют контракт.

Группы:

| Группа | Resolvers / блоки | Источник |
|--------|-------------------|----------|
| Voice | `identity` | PG: `identity.private` \| `identity.group` — `createArityResolver` |
| Turn | `turn_handling` | PG |
| Answer envelope | `response_format` | PG — JSON object, camelCase |
| Answer policy | `conversation_settings.timezone`, … | PG + conditional resolvers; per-field — [#59](https://github.com/skepsik/utlas-ts/issues/59) |
| Transport | `addressing.telegram_group` | PG; **omit** unless `arity=group` && `transport=telegram` |
| Voice | `burst` | PG: `burst.private` \| `burst.group` |
| Style / constraints | `constraints_context`, `communication_style`, `response_length_structure`, `frame_handling`, `content_strategy`, `strict_prohibitions` | PG |
| Heuristic | `followup_appendix` | PG; **omit** unless `isFollowupAppendixTurn` |

**Переходный:** `answerSchemaResolver` (псевдо-TS из zod) — убрать, когда answer-path только structured output; форма в адаптере — [llm-jobs](./llm-jobs.md).

Новая system-секция: row в `prompt_blocks` + resolver в массиве `prompt-composer.ts`.

---

## User chain (answer profile)

**Порядок — в коде:** `userResolvers` в `prompt-composer.ts`.

| Блок                | Resolver                 | Данные                                      |
| ------------------- | ------------------------ | ------------------------------------------- |
| Timestamps meta     | `timestampsMetaResolver` | `effectiveTz` из settings — факт для ленты  |
| **CHAT HISTORY**    | `chatHistoryResolver`    | `selectRecentBefore` → `formatThread`       |
| **SEMANTIC THREAD** | `semanticThreadResolver` | `buildSemanticThread` → `formatThread`      |
| **USER MESSAGE**    | `userMessageResolver`    | anchor + `queryText`, optional reply parent |

Порядок user-слотов (meta → history → thread → message) — контракт envelope

---

## PG `prompt_blocks`

```text
prompt_blocks (key UNIQUE, text, is_enabled)
```

- `loadPromptBlock(pg, key)` — missing key → throw; `is_enabled=false` → `null` (секция omit).
- Редактирование **текста** — в БД; **порядок и conditional logic** — resolvers в git.
- Manifest / user-editable order в PG — **не** делаем.

### Ключи `prompt_blocks`

| Паттерн              | Примеры                                   | Выбор ключа                                                                                                 |
| -------------------- | ----------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| flat                 | `turn_handling`, `response_format`        | фиксированная строка в resolver                                                                             |
| arity                | `identity.private`, `burst.group`         | `createArityResolver(stem)` → `stem.private` \| `stem.group`                                                |
| transport / сценарий | `addressing.telegram_group`               | custom resolver; часть после `.` — **пока без общей схемы** (только этот ключ)                              |
| вариант фичи         | `scratchpad_init`, `scratchpad_reconcile` | `snake_case`, `_` между stem и ролью; conditional compose — [scratchpad](./envelope/scratchpad.md) § Промпт |

Wire JSON answer — [envelope](./envelope/index.md). Ключи `prompt_blocks` — таблица выше.

---

## Форматирование (`format.ts`)

Сообщения в envelope:

- Обёртка: `=== NAME ===` … `=== END NAME ===`
- Строка: `[UTC time] Sender (@handle):` или `(bot)`
- Reply: `↩ reply to [time] author:`
- Quote: `[quote]` … `[end quote]`
- Forward: `[forward from: label, originAt]`
- User message body — `queryText` (burst / override), не сырой `anchor.body` если задан override

---

## Ошибки resolvers

`buildSection`:

- `PromptComposeFatalError` → abort всего `compose` (missing PG block, unsupported arity).
- Любая другая ошибка → log + **omit** секции (user envelope best-effort).

---

## Расширение

| Нужно | Как |
|-------|-----|
| Новый derived input | `once()` getter на `PromptShared` |
| Новый PG block | migration/seed + `createTextBlockResolver` или custom resolver |
| Conditional block | resolver возвращает `null` → omit |
| Tools list в system | [tools](./tools/index.md) — `availableToolsResolver` (planned #38) |
| Второй LLM (inference, local) | [llm-jobs](./llm-jobs.md) — `runLlmJob`, свой profile + strategy |

---

## Answer prompt layers

Envelope + per-field policy в system; **форма объекта** — wire schema в адаптере (structured output), не дублировать псевдо-TS в compose — [llm-jobs](./llm-jobs.md) § Промпт answer, [#59](https://github.com/skepsik/utlas-ts/issues/59).

---

## Rejected: contributors / signals / merge

`Contributor → mergeSignalPatches` — **не делаем**: дедуп уже в `once()` / `loadBlock` Map; patch-merge — footgun. Dynamic writers — отдельный дизайн под конкретный registry.

---

## Later

- Group meta-visibility content — [#20](https://github.com/skepsik/utlas-ts/issues/20)
- Enrichment fragments в compose — [turn-pipeline](./turn-pipeline.md)
- `TurnCapabilities` / tools-aware compose — [turn-pipeline](./turn-pipeline.md) § Later
- Shared context для multi-bot — [context-bus](./prompts/context-bus.md) (spike)
- Retrieval trim/rank — stub `retrieval/`
