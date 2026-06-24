# Declarative snapshots

**Журнал declarative-снимков** — append-only хранение model-owned состояния, которое модель патчит через declare-фазу [answer envelope](./index.md) (full replace, omit = без изменений).

Это **не** сущность конкретного поля. [Scratchpad](./scratchpad.md) — первый **вид** (`kind`) снимка; завтра может появиться другой, с той же механикой журнала.

Envelope hub: [index](./index.md).

---

## Зачем отдельно от scratchpad

| Слой | Что описывает |
|------|----------------|
| **Declarative snapshots** (эта страница) | универсальный способ хранить снимки на ход: insert, load effective, watermark |
| **Scratchpad** | семантика одного `kind`: слоты, промпт, validate/truncate |

Даже если `scratchpad` навсегда останется единственным `kind`, журнал — самостоятельная абстракция.

---

## Что попадает в журнал

**Да** — declarative state, которое:

- модель возвращает в envelope (declare, не tool loop);
- full replace на ход; omit = не писать snapshot;
- нужно удерживать **между ходами** без перечитывания всей ленты.

**Нет** — другие каналы:

| Механизм | Хранение |
|----------|----------|
| `conversationSettings` | колонки / settings сущности чата; server-validated |
| `blockTtl` / compose blocks | patch по `blockId`, TTL — [compose-blocks](./compose-blocks.md) |
| semantic thread | вычисляется на compose, не snapshot модели |

---

## Таблица: `declarative_snapshots`

Не колонка в `chats` — отдельная таблица с полной историей.

```text
declarative_snapshots
  id                   serial PK
  transport            text NOT NULL
  conversation_id      text NOT NULL
  trigger_message_id   text NOT NULL
  kind                 text NOT NULL          -- scratchpad | …
  payload              jsonb NOT NULL
  created_at           timestamptz NOT NULL DEFAULT now()
  UNIQUE (transport, conversation_id, trigger_message_id, kind)
  INDEX (transport, conversation_id, kind, trigger_message_id)
```

`kind` — вид снимка. `payload` — тело после validate (и truncate, если применимо к этому `kind`).

**v0:** единственный `kind = 'scratchpad'` — см. [scratchpad](./scratchpad.md).

---

## Семантика

| Событие | Поведение |
|---------|-----------|
| Поле в answer **omit** | snapshot этого `kind` на ход **не** пишем; effective = предыдущий в видимом окне |
| Поле **present**, valid | insert row (`kind`, `payload`) |
| Поле **invalid** | не insert; effective без изменений |
| Нет строк после load | empty effective для этого `kind` (для scratchpad — четыре `[]` / null) |

На одном `trigger_message_id` может быть **несколько** строк с разными `kind` (сегодня обычно одна).

---

## Load effective

Перед compose (per `kind`):

```text
watermark = getContextResetFloor(chat)
SELECT payload FROM declarative_snapshots
  WHERE transport = ? AND conversation_id = ? AND kind = ?
    AND CAST(trigger_message_id AS bigint) >= watermark
  ORDER BY CAST(trigger_message_id AS bigint) DESC
  LIMIT 1
```

Handler per `kind`: deserialize, подставить в промпт (для scratchpad — `[[CURRENT_SCRATCHPAD_STATE]]`).

---

## Insert

Только после **успешного** turn, когда в ответе был валидный declarative patch этого `kind`.

Цепочка per kind (на примере scratchpad): parse → validate → truncate → insert. Детали validate/truncate — у [вида](./scratchpad.md), не здесь.

---

## Связь с `/forget`

Forget двигает `conversations.context_reset_after_message_id`. Строки журнала **не удаляем** — snapshots с `trigger_message_id < watermark` выпадают из выборки effective.

Отдельного reset журнала нет.

---

## Backend (концепт)

```text
storage/declarative-snapshots/   load effective, insert
turn/                            apply declarative patches → insert per kind
```

Регистр `kind` → handler (validate, truncate, compose slot). Новый вид — новый handler + envelope field, не новая таблица.

---

## Out of scope

- patch-семантика внутри `payload`
- `/unforget` / admin rewind watermark
- prune / retention policy
- user-facing viewer снимков
