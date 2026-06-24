# Turn prompt

Сборка `LlmPrompt` для turn: **composer** в `@utlas/core/llm/prompt/`; default resolver chains — `apps/runtime/src/llm/`. Текст policy — в PG `prompt_blocks`; порядок секций — resolvers в git.

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

## System resolvers (`defaultSystemResolvers`)

Порядок фиксирован в `composer.ts`. Блоки — `prompt_blocks.key` через `loadBlock`, кроме conditional resolvers.

| # | Resolver | Источник |
|---|----------|----------|
| 1 | `identity` | PG: `identity.private` \| `identity.group` — `createArityResolver("identity")` |
| 2 | `turn_handling` | PG |
| 3 | `response_format` | PG — JSON answer schema hint |
| 4 | `addressing.telegram_group` | PG; custom resolver; **omit** unless `arity=group` && `transport=telegram` |
| 5 | `burst` | PG: `burst.private` \| `burst.group` — `createArityResolver("burst")` |
| 6 | `constraints_context` | PG |
| 7 | `communication_style` | PG |
| 8 | `response_length_structure` | PG |
| 9 | `followup_appendix` | PG `followup_appendix`; **omit** unless heuristic `isFollowupAppendixTurn` |
| 10 | `frame_handling` | PG |
| 11 | `content_strategy` | PG |
| 12 | `strict_prohibitions` | PG |

Новая system-секция: row в `prompt_blocks` + resolver в массиве (место в git).

---

## User resolvers (`defaultUserResolvers`)

| # | Блок | Resolver | Данные |
|---|------|----------|--------|
| 1 | **CHAT HISTORY** | `chatHistoryResolver` | `selectRecentBefore` → `formatThread` |
| 2 | **SEMANTIC THREAD** | `semanticThreadResolver` | `buildSemanticThread` → `formatThread` |
| 3 | **USER MESSAGE** | `userMessageResolver` | anchor + `queryText`, optional reply parent |

Порядок зафиксирован в коде и тестах (`prompt-composer.test.ts`).

---

## PG `prompt_blocks`

```text
prompt_blocks (key UNIQUE, text, is_enabled)
```

- `loadPromptBlock(pg, key)` — missing key → throw; `is_enabled=false` → `null` (секция omit).
- Редактирование **текста** — в БД; **порядок и conditional logic** — resolvers в git.
- Manifest / user-editable order в PG — **не** делаем.

### Ключи `prompt_blocks`

| Паттерн | Примеры | Выбор ключа |
|---------|---------|-------------|
| flat | `turn_handling`, `response_format` | фиксированная строка в resolver |
| arity | `identity.private`, `burst.group` | `createArityResolver(stem)` → `stem.private` \| `stem.group` |
| transport / сценарий | `addressing.telegram_group` | custom resolver; часть после `.` — **пока без общей схемы** (только этот ключ) |
| вариант фичи | `scratchpad_init`, `scratchpad_reconcile` | `snake_case`, `_` между stem и ролью; conditional compose — [scratchpad](./envelope/scratchpad.md) § Промпт |

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
