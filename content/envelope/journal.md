# Journal

**Scratchpad / journal** — per-chat рабочая память модели: модель сама ведёт сжатый контекст (о чём говорим, факты, prefs чата), отдельно от ленты сообщений и prompt blocks.

- **Per-chat** (private и group): у модели нет сущности user в group; «обращаться на ВЫ» и т.п. — в journal чата.
- **Full replace**, не patch-DSL: модель отдаёт целый `journal` или **omit** (не менять).
- **История в PG** — append-only snapshots; effective journal выводится из watermark `/forget`, без отдельного reset journal.

Envelope hub: [index](./index.md).

---

## Контракт ответа LLM

**Top-level** optional поле `journal` в answer envelope. Declarative patch (после tool loop, до egress); **не** `toolCalls`.

```json
{
  "shouldReply": true,
  "text": "…",
  "journal": {
    "context": "о чём сейчас говорим",
    "facts": ["факт 1", "факт 2"]
  }
}
```

| Правило | Поведение |
|--------|-----------|
| `journal` **omit** | snapshot не пишем; effective = предыдущий в видимом окне |
| `journal` **present** | full replace → новый snapshot (после validate + truncate) |
| `journal` **invalid** (schema / size) | snapshot не пишем; effective без изменений |
| «Очистить» journal | пустые поля в объекте (`context: ""`, `facts: []`), блок всё равно присутствует |

Внутренняя структура `journal` — свободная (zod: object, без жёсткой схемы полей на v0). Поле нужно только для parse.

Egress пользователю — только `text` (+ существующий debug). Journal в обычный ответ не уходит.

---

## Хранение: `journal_snapshots`

Не колонка в `chats` — отдельная таблица с полной историей.

```text
journal_snapshots
  id                   serial PK
  transport            text NOT NULL
  conversation_id      text NOT NULL
  trigger_message_id   text NOT NULL
  journal              jsonb NOT NULL
  created_at           timestamptz NOT NULL DEFAULT now()
  UNIQUE (transport, conversation_id, trigger_message_id)
  INDEX (transport, conversation_id, trigger_message_id)
```

**Insert** — только после успешного turn, когда в ответе был валидный `journal`.

**Load effective** (перед compose):

```text
watermark = getContextResetFloor(chat)
SELECT journal FROM journal_snapshots
  WHERE transport = ? AND conversation_id = ?
    AND CAST(trigger_message_id AS bigint) >= watermark
  ORDER BY CAST(trigger_message_id AS bigint) DESC
  LIMIT 1
```

→ нет строк: пустой journal (`{}` / null).

### Связь с `/forget`

Forget только двигает `conversations.context_reset_after_message_id`. Journal **не чистим** — snapshots с `trigger_message_id < watermark` выпадают из выборки.

---

## Промпт

- Prompt block `journal_instructions` (слот `[[CURRENT_JOURNAL_STATE]]`, `MAX_JOURNAL_SIZE`).
- `response_format` — упоминание optional `journal`.
- Poisoning: system / safety blocks важнее journal.

---

## Backend (концепт)

| Шаг | Действие |
|-----|----------|
| compose | load effective journal → `[[CURRENT_JOURNAL_STATE]]` |
| parse | answer schema (+ optional `journal`) |
| post-parse | validate → truncate по `MAX_JOURNAL_SIZE` |
| save | insert snapshot при валидном `journal` |
| invalid | не save; debug egress — факт ошибки |

---

## Debug mode ([#44](https://github.com/skepsik/utlas-ts/issues/44))

- Diff journal: `before` vs `after` (structural).
- Invalid journal: короткая пометка в debug egress.

---

## Out of scope

- per-user journal в group
- patch-семантика facts
- `/unforget` / admin rewind watermark
- prune / retention policy
- `/settings journal` viewer
