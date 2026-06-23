# Scratchpad

**Scratchpad** — per-chat внутреннее представление модели: сухой остаток совместной работы, отдельно от ленты сообщений, semantic thread и compose-blocks. Не CoT, не энциклопедия, не user-facing UI.

- **Per-chat** (private и group): у модели нет сущности user в group; «обращаться на ВЫ» и т.п. — в scratchpad чата, пока не формализовано в `conversationSettings`.
- **Full replace**, не patch-DSL: модель отдаёт целый `scratchpad` или **omit** (не менять).
- **История в PG** — append-only snapshots; effective scratchpad выводится из watermark `/forget`, без отдельного reset.

Фокус хода — `USER_MESSAGE` (якорь) и `SEMANTIC_THREAD` (если вычислен). Scratchpad **не** дублирует running summary: отдельного поля «о чём говорим» нет.

Envelope hub: [index](./index.md).

---

## Что хранить (и что нет)

| Слот | Содержимое | Примеры |
|------|------------|---------|
| `decisions` | Договорённости и выводы *этого* диалога/задачи | «Делаем X», «выбрали стек Y» |
| `constraints` | Жёсткие границы зоны ответственности и допустимых тем | «Не политика», «только код» |
| `unresolved_questions` | Мета-описание незакрытых долгов, блокирующих работу | «Дедлайн не согласован», не цитата юзера |
| `user_preferences` | Мягкие пожелания по стилю или выбору | «Короче», «на ты», «сначала план» |

**Не писать в scratchpad:**

- энциклопедические факты («Париж — столица Франции») — общие знания, не специфика чата;
- running summary / пересказ чата — есть лента и semantic thread;
- дубли последнего `USER_MESSAGE` — якорь уже в промпте.

**`conversationSettings` vs scratchpad:** формальные server-validated поля (сейчас `timezone`) — в settings. Soft prefs — в `user_preferences`, пока не выросли в формальное поле settings.

---

## Контракт ответа LLM

**Top-level** optional поле `scratchpad` в answer envelope. Declarative patch (после tool loop, до egress); **не** `toolCalls`.

```json
{
  "shouldReply": true,
  "text": "…",
  "scratchpad": {
    "decisions": ["делаем API v2"],
    "constraints": ["не обсуждать политику"],
    "unresolved_questions": ["дедлайн не согласован"],
    "user_preferences": ["отвечать короче"]
  }
}
```

```ts
type Scratchpad = {
  decisions: string[];
  constraints: string[];
  unresolved_questions: string[];
  user_preferences: string[];
};
```

| Правило | Поведение |
|--------|-----------|
| `scratchpad` **omit** | snapshot не пишем; effective = предыдущий в видимом окне |
| `scratchpad` **present** | full replace → новый snapshot (после validate + truncate) |
| `scratchpad` **invalid** (schema / size) | snapshot не пишем; effective без изменений |
| «Очистить» scratchpad | четыре пустых массива `[]`, блок всё равно присутствует |

Строгая zod-схема: четыре массива строк, без лишних полей. Per-item length cap — отдельный лимит на длину одной строки.

Egress пользователю — только `text` (+ debug). Scratchpad в обычный ответ не уходит.

---

## `unresolved_questions`

Модель видит **текущее окно целиком** (`USER_MESSAGE`, thread, scratchpad) и сама отсеивает мимолётное от системных затыков. Жёсткий алгоритм на бэкенде не нужен — критерии в промпте.

**Писать**, если одновременно:

- без записи следующий ход может действовать неверно или потерять нить;
- тема **не закрыта** в видимом окне;
- пункт — **мета** («дедлайн не уточнён»), не цитата и не пересказ последнего сообщения.

**Не писать:**

- вопрос **в** последнем `USER_MESSAGE` (это якорь хода);
- уже отвеченное или контекстно устаревшее в окне;
- мимолётное любопытство, риторические вопросы.

Промпт: *«ищи незакрытые долги, не перечисляй вопросительные знаки»*; каждый пункт — одна короткая строка. **Cap:** не больше 3–5 пунктов.

При full replace модель **пересобирает** все четыре массива; закрытый в окне долг **удаляет** из `unresolved_questions`.

Тест для модели: *«если уберу этот пункт, могу на следующем ходу ошибиться?»* — нет → не писать.

---

## Размер и truncate

Два слоя — предупреждение модели **и** hard cap бэкенда.

**Compose (мягкий слой):**

- load effective scratchpad → measure size;
- inject в `[[CURRENT_SCRATCHPAD_STATE]]` бюджет, напр. `742 / 1024 bytes`;
- при `size > SOFT_THRESHOLD` (напр. 80% `MAX_SCRATCHPAD_SIZE`) — warning в `scratchpad_instructions`: сжать, убрать устаревшее, не добавлять без удаления старого.

**Post-parse (жёсткий слой):**

- validate strict schema;
- если всё ещё `> MAX_SCRATCHPAD_SIZE` → truncate по приоритету слотов (с конца низкоприоритетных):
  1. `constraints` — резать последними;
  2. `decisions`;
  3. `unresolved_questions`;
  4. `user_preferences` — резать первыми.
- invalid → не save; debug egress — факт ошибки / truncation.

Умный промпт снижает частоту грубой обрезки, но не снимает гарантию размера.

---

## Хранение: `scratchpad_snapshots`

Не колонка в `chats` — отдельная таблица с полной историей.

```text
scratchpad_snapshots
  id                   serial PK
  transport            text NOT NULL
  conversation_id      text NOT NULL
  trigger_message_id   text NOT NULL
  scratchpad           jsonb NOT NULL
  created_at           timestamptz NOT NULL DEFAULT now()
  UNIQUE (transport, conversation_id, trigger_message_id)
  INDEX (transport, conversation_id, trigger_message_id)
```

**Insert** — только после успешного turn, когда в ответе был валидный `scratchpad`.

**Load effective** (перед compose):

```text
watermark = getContextResetFloor(chat)
SELECT scratchpad FROM scratchpad_snapshots
  WHERE transport = ? AND conversation_id = ?
    AND CAST(trigger_message_id AS bigint) >= watermark
  ORDER BY CAST(trigger_message_id AS bigint) DESC
  LIMIT 1
```

→ нет строк: пустой scratchpad (четыре `[]` / null).

### Связь с `/forget`

Forget только двигает `conversations.context_reset_after_message_id`. Snapshots **не чистим** — строки с `trigger_message_id < watermark` выпадают из выборки.

---

## Промпт

- Prompt block `scratchpad_instructions` (слот `[[CURRENT_SCRATCHPAD_STATE]]`, `MAX_SCRATCHPAD_SIZE`, `SOFT_THRESHOLD`).
- `response_format` — optional `scratchpad` и четыре слота.
- Poisoning: system / safety blocks важнее scratchpad.

---

## Backend (концепт)

| Шаг | Действие |
|-----|----------|
| compose | load effective → `[[CURRENT_SCRATCHPAD_STATE]]` + budget/warning |
| parse | answer schema (+ optional `scratchpad`) |
| post-parse | validate → truncate по `MAX_SCRATCHPAD_SIZE` |
| save | insert snapshot при валидном `scratchpad` |
| invalid | не save; debug egress — факт ошибки |

---

## Debug mode ([#44](https://github.com/skepsik/utlas-ts/issues/44))

- Diff scratchpad: `before` vs `after` (structural, по слотам).
- Invalid / truncated: короткая пометка в debug egress.

---

## Out of scope

- per-user scratchpad в group
- patch-семантика отдельных слотов
- `/unforget` / admin rewind watermark
- prune / retention policy
- user-facing viewer scratchpad
