# Scratchpad

**Scratchpad** — per-chat внутреннее представление модели: сухой остаток совместной работы, отдельно от ленты сообщений, semantic thread и compose-blocks. Не CoT, не энциклопедия, не user-facing UI.

- **Per-chat** (private и group): у модели нет сущности user в group; «обращаться на ВЫ» и т.п. — в scratchpad чата, пока не формализовано в `conversationSettings`.
- **Full replace**, не patch-DSL: модель отдаёт целый `scratchpad` или **omit** (не менять).
- **История в PG** — append-only snapshots; effective scratchpad выводится из watermark `/forget`, без отдельного reset.

Фокус хода — `USER_MESSAGE` (якорь) и `SEMANTIC_THREAD` (если вычислен). Scratchpad **не** дублирует running summary: отдельного поля «о чём говорим» нет.

Envelope hub: [index](./index.md).

---

## Зачем (error budget)

Scratchpad — не система хранения истины, а **механизм снижения типовых сбоев** длинного диалога. Источник фактов чата — лента, semantic thread, search. Scratchpad — **стабилизатор поведения** между ходами: сухой остаток того, что иначе модель стабильно теряет.

**Что убирает** (системные ошибки — без scratchpad случаются предсказуемо):

| Ошибка | Проявление |
|--------|------------|
| Забытые договорённости | Модель отступает от решённого между ходами |
| Переспрос | Снова спрашивает то, что уже выяснили в чате |
| Противоречия | Разные ответы в длинном диалоге на одну и ту же тему |

**Что добавляет** (калибруемые ошибки — промпт, практика, лимиты):

| Ошибка | Рычаг |
|--------|-------|
| Накопительство | Критерии слотов, omit, reconcile по delta **состояния** |
| Лишние апдейты | `scratchpad_reconcile`, не delta окна |
| Не тот слот | Семантика в `scratchpad_slots`, strict schema |
| Потеря при truncate | Soft warning, backend priority (скрыт от модели); частично — лимиты |

Ключевое различие: первые — **структурные** (контекстное окно и inference), вторые — **управляемые**. Дизайн scratchpad осознанно меняет error budget: принимаем калибруемый шум ради устранения системных сбоев.

Eval и debug: не «полнота scratchpad», а регрессии по забытым договорённостям / переспросу / противоречиям vs шум (лишние записи, truncate).

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
| Явный сброс по просьбе юзера | present + все `[]` (не omit) — см. [scratchpad_reconcile](#scratchpad_reconcile) |

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
- при `size > SOFT_THRESHOLD` (напр. 80% `MAX_SCRATCHPAD_SIZE`) — warning в `scratchpad_slots`: сжать, убрать устаревшее, не добавлять без удаления старого (**без** порядка слотов при truncate — см. [Rejected](#rejected-приоритет-truncate-в-промпте)).

**Post-parse (жёсткий слой):**

- validate strict schema;
- если всё ещё `> MAX_SCRATCHPAD_SIZE` → truncate по приоритету слотов (с конца низкоприоритетных):
  1. `constraints` — резать последними;
  2. `decisions`;
  3. `unresolved_questions`;
  4. `user_preferences` — резать первыми.
- invalid → не save; effective без изменений; debug egress — факт ошибки.
- truncated (после validate, до save) → save урезанный snapshot; debug egress — факт truncation.

Детали validate/truncate — [открытые вопросы](#validate--truncate-backend) (лимиты, единица измерения, гранулярность обрезки).

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

Промпты формируются **исключительно под отправляемый контекст** — отдельные PG-блоки, compose включает по условиям.

**Статус текстов:**

| Блок | Статус |
|------|--------|
| `scratchpad_reconcile` | **Канонический текст** — copy в PG block as-is |
| `scratchpad_search_rule` | **Канонический текст** — copy в PG block as-is |
| `scratchpad_init` | **Канонический текст** — copy в PG block as-is |
| `scratchpad_slots` | **ТЗ к PG block** — собрать из секций выше + подстановки `[[…]]` |

`response_format` — optional `scratchpad` и четыре слота (wire schema). Poisoning: system / safety blocks важнее scratchpad.

### Compose (условия)

```text
scratchpad_slots        — scratchpad-ветка активна (init или reconcile)
scratchpad_init         — scratchpad-ветка ∧ нет [[CURRENT_SCRATCHPAD_STATE]]
scratchpad_reconcile    — scratchpad-ветка ∧ есть [[CURRENT_SCRATCHPAD_STATE]]
scratchpad_search_rule  — scratchpad-ветка ∧ search_messages ∈ availableTools
```

`scratchpad_search_rule` **не** включается при одном search без scratchpad-ветки.

Слот `[[CURRENT_SCRATCHPAD_STATE]]` — сериализованный effective scratchpad + бюджет (`742 / 1024 bytes`); warning при `> SOFT_THRESHOLD` — часть `scratchpad_slots`.

---

### `scratchpad_slots` (ТЗ)

PG block: семантика слотов (таблица [выше](#что-хранить-и-что-нет)), «не энциклопедия», критерии [`unresolved_questions`](#unresolved_questions), cap 3–5, truncate warning при превышении порога. **Не включать** приоритет слотов при backend truncate. Точная формулировка — при authoring PG block; содержание — по этой странице.

---

### `scratchpad_init` (канон)

```text
Если по критериям слотов есть информация, которую нужно удерживать между ходами, — верни scratchpad (все четыре слота).
Если хранить нечего — не включай scratchpad в ответ.
```

---

### `scratchpad_reconcile` (канон)

```text
Ниже текущее состояние scratchpad. После анализа всего видимого окна оцени, должно ли состояние scratchpad выглядеть иначе сейчас.

Верни новый scratchpad только если хотя бы один пункт нужно:
- добавить;
- удалить как устаревший или закрытый;
- переформулировать для большей точности (не ради стиля, если текущая формулировка уже достаточна).

Если пользователь явно просит забыть всё / начать с чистого листа — верни все слоты как [].

Иначе не включай scratchpad в ответ.
```

Критерий — **delta состояния**, не delta окна: новое сообщение в чате само по себе не повод для апдейта (напр. decision «используем PostgreSQL» + «PostgreSQL отлично себя показывает» → omit).

---

### `scratchpad_search_rule` (канон)

```text
Не используй search_messages как замену scratchpad: если информация должна влиять на будущие ответы независимо от того, будет ли выполнен поиск, она должна быть в scratchpad.
```

Связь с [message-search](../tools/message-search.md): search — детали и цитаты из архива; compose blocks — временный кэш (TTL). Scratchpad — обязательства между ходами.

---

## Backend (концепт)

| Шаг | Действие |
|-----|----------|
| compose | load effective → `[[CURRENT_SCRATCHPAD_STATE]]` + budget/warning |
| parse | answer schema (+ optional `scratchpad`) |
| post-parse | validate → truncate по `MAX_SCRATCHPAD_SIZE` |
| save | insert snapshot при прошедшем validate (в т.ч. после truncate) |
| invalid | не save; debug egress — факт ошибки |
| truncated | save урезанный snapshot; debug egress — факт truncation |

---

## Debug mode ([#44](https://github.com/skepsik/utlas-ts/issues/44))

- Diff scratchpad: `before` vs `after` (structural, по слотам).
- Invalid / truncated: короткая пометка в debug egress.

---

## Открытые вопросы

### Validate / truncate (backend)

Зафиксировано: strict schema (четыре массива строк); invalid → не save; truncate по приоритету слотов (`user_preferences` → … → `constraints`); truncated → save + debug. **Приоритет слотов — только backend**, в промпт не передаём (см. [Rejected](#rejected-приоритет-truncate-в-промпте)). **Числа и алгоритм — при work-issue.**

| # | Вопрос | Варианты / заметки |
|---|--------|-------------------|
| 1 | `MAX_SCRATCHPAD_SIZE` | Стартовое значение? (напр. 1–2 KiB JSON) |
| 2 | `SOFT_THRESHOLD` | Доля от max (80%?) или абсолют в compose |
| 3 | Единица измерения | UTF-8 bytes сериализованного JSON vs runes vs «bytes как в промпте» — compose и post-parse должны совпадать |
| 4 | `MAX_SCRATCHPAD_ITEM_LENGTH` | Per-item cap до slot-truncate; значение |
| 5 | Гранулярность truncate | Целиком удалять элементы с хвоста массива vs обрезать строку внутри элемента |
| 6 | Порядок внутри массива | FIFO с конца (последний добавленный первым на удаление?) |
| 7 | После truncate всё ещё > max | Ещё раунды по слотам до влезания vs reject как invalid |
| 8 | Cap `unresolved_questions` (3–5) | Только промпт или enforce на validate (лишние → truncate/reject) |
| 9 | Пустые строки в массивах | Допустимы vs reject; фильтровать на save |
| 10 | Дубликаты в одном слоте | Dedupe на save или как прислала модель |
| 11 | Truncation vs invalid в egress | Достаточно debug-пометки или отдельный флаг/метрика для мониторинга частоты |

### Rejected: приоритет truncate в промпте

Раскрывать модели порядок слотов при hard truncate (**не делаем**): зная, что `user_preferences` режутся первыми, а `constraints` — последними, модель может класть важное в «защищённый» слот вместо семантически верного (дедлайн в `constraints`, prefs в `constraints` и т.п.). Слоты — типы информации, не уровни приоритета хранения.

Модели: бюджет, soft warning, «убери устаревшее / сожми». Бэкенду: приоритет слотов и hard truncate.

---

## Out of scope

- per-user scratchpad в group
- patch-семантика отдельных слотов
- `/unforget` / admin rewind watermark
- prune / retention policy
- user-facing viewer scratchpad
