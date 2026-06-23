# Message search

**Message search tool** — LLM tool call для поиска по сообщениям чата. Модель передаёт **поисковый объект** (не SQL); backend компилирует в безопасный запрос.

Цель: структурированный поиск и пагинация **внутри того множества сообщений, которое storage отдаёт как доступное** — когда в compose не влезает вся лента, но нужно найти по тексту / дате / отправителю.

Инфраструктура tool loop — [#38](https://github.com/skepsik/utlas-ts/issues/38). Journal — [journal](./journal.md).

---

## Answer envelope ([llm-envelope](./llm-envelope.md))

Два канала — **не смешивать**:

| Канал | Когда | Что |
|-------|-------|-----|
| `toolCalls` → `search_messages` | tool loop (execute) | поиск + **создание** block; начальный `ttlTurns` в args query |
| top-level `blockTtl` | финальный answer (declare) | **только** TTL patch / revoke существующих `blockId` без нового tool call |

`blockTtl` **не** уходит в `toolCalls` (не synthetic tool). Top-level sibling рядом с `journal`, `conversationSettings` ([llm-envelope](./llm-envelope.md)).

---

## Доступ к сообщениям — через port

Единственный путь чтения — **storage port** (аналог `MessageReadPort`), который возвращает только **доступные** записи. Те же правила видимости, что для context window и compose.

- Search runner и hydrate блоков ходят **только** через port / общий visibility layer в `storage/`.
- Смена visibility (`/forget`, движение watermark в любую сторону) — детали storage; tool и compose **не дублируют** floor-логику.
- Следующий search и следующий compose **автоматически** отражают новую границу видимости.

---

## Tool surface (v0)

Имя tool TBD, e.g. `search_messages`. Аргумент — `MessageSearchQuery`:

| # | Поле | Тип | Назначение |
|---|------|-----|------------|
| 1 | `content` | string | Текстовый поиск (substring / pattern — см. ниже) |
| 2 | `senderId` | string \| string[] | Фильтр по `user_id` |
| 3 | `dateFrom` | ISO date/datetime | Начало диапазона |
| 4 | `dateTo` | ISO date/datetime | Конец диапазона |
| 5 | `lengthMin` | int | Мин. длина `text` |
| 6 | `lengthMax` | int | Макс. длина `text` |
| 7 | `isReply` | boolean | Только ответы |
| 8 | `limit` | int | Сколько строк вернуть |
| 9 | `offset` | int | Пагинация |
| 10 | `sortBy` | enum | `date_asc` \| `date_desc` \| `length_asc` \| `length_desc` |
| 11 | `ttlTurns` | int | Сколько **следующих turn'ов** держать результат в compose |

Все поля **optional**; пустой query = «последние N» в доступном множестве.

### Later (не v0)

- `hasMedia`, `entityType` — нужен persist / ingress metadata

### `content`

- v0: **substring** (`ILIKE` / trgm later)
- later: regex с server-side caps

### Ответ tool (в tool loop)

Полные hits — для немедленного tool output в текущем turn:

```ts
MessageSearchHit = { messageId, sentAt, userId, displayName, text, isReply, replyToMessageId? }

SearchToolResult = {
  blockId: string;
  hits: MessageSearchHit[];
  truncated: boolean;
}
```

---

## Блоки результатов (кэш между turn'ами)

После успешного search создаётся **блок** в PG; на следующих turn'ах активные блоки — отдельные секции в compose. **Несколько блоков** от разных query могут coexist.

Блок — **кэш ссылок**, не снимок текста: в PG храним `messageId` (порядок сохраняем); актуальное содержимое — **hydrate on compose** через visibility port.

### Общая TTL-механика ([llm-envelope](./llm-envelope.md))

Top-level `blockTtl` в answer — **generic** для любых compose-blocks (`message_search`, позже FTS и др.). Модель patch'ит только `{ blockId, ttlTurns }`; `kind` знает backend по PG.

Создание блока — всегда через `toolCalls` (здесь: `search_messages`).

### Хранение (концепт)

Единая таблица (не только search):

```text
compose_blocks
  kind               text NOT NULL          -- message_search | fts | …
  block_id           text NOT NULL          -- uuid, UNIQUE per chat
  transport          text NOT NULL
  conversation_id    text NOT NULL
  trigger_message_id text NOT NULL
  query              jsonb NOT NULL
  hit_message_ids    jsonb NOT NULL          -- string[] упорядоченных messageId
  ttl_turns          int NOT NULL
  created_at         timestamptz
```

При создании блока из tool result: `hit_message_ids` = ids из hits (текст в PG блока не дублируем).

### Hydrate on compose

1. Load блоков с `ttl_turns > 0`.
2. Для каждого `messageId` в `hit_message_ids` → `MessageReadPort.getMessage(...)` (или общий visibility helper).
3. `null` / недоступно → skip (сообщение «выпало» из видимости — в т.ч. после `/forget` или сдвига watermark).
4. Собранные hits → секция в prompt; **пустой блок после hydrate** → не inject'ится.
5. Блок в PG не удаляем и не «инвалидируем» событием — visibility меняется на стороне port, hydrate отражает это на каждом compose.

### TTL — на откуп модели

- `ttlTurns` при `search_messages` задаёт модель; backend clamp (`MAX_TTL_TURNS`).
- Декремент `ttl_turns` — **один раз на завершённый user-turn** (граница turn — [turn-pipeline](./turn-pipeline.md); детали привязки — в work-issue, не здесь).
- `ttl_turns <= 0` → блок не в compose.

**Продление / revoke** — top-level `blockTtl` в answer envelope ([llm-envelope](./llm-envelope.md)), по аналогии с `journal` (только затронутые blockId):

```json
{
  "shouldReply": true,
  "text": "…",
  "blockTtl": [
    { "blockId": "…", "ttlTurns": 5 },
    { "blockId": "…", "ttlTurns": 0 }
  ]
}
```

- Omit `blockTtl` → TTL без изменений.
- `ttlTurns: 0` → revoke.
- Только перечисленные `blockId` обновляются.

Отдельно от journal ([journal](./journal.md)): journal — сжатая память; search blocks — кэш id + hydrate.

### Параллельные запросы

Каждый search → новый `blockId` (reuse blockId — open question).

---

## Инварианты

- **Scope**: `(transport, conversation_id)` текущего turn.
- **Visibility**: только через storage port.
- **Read-only** относительно `messages`.
- **Caps**: limit, hit text size on hydrate, max active blocks, max TTL.

---

## Размещение (ориентир)

```text
storage/
  ports.ts                 # MessageSearchPort + hydrate через MessageReadPort
  message-search/          # compile query, execute через port
  compose-blocks/          # persist, TTL tick, apply blockTtl

tools/runners/message-search/
turn/                      # tool loop, TTL decrement, apply blockTtl from answer
llm/                       # compose resolver: load blocks → hydrate → inject
```

---

## Связь с context window

| Механизм | Что даёт |
|----------|----------|
| Visibility port (`storage/`) | какие сообщения существуют для модели |
| Context window (compose) | недавняя лента (лимит N) |
| Journal ([journal](./journal.md)) | сжатые факты |
| Search tool | разовый запрос через port |
| Compose blocks (`kind: message_search`) | кэш `messageId` + hydrate on compose; TTL via `blockTtl` ([llm-envelope](./llm-envelope.md)) |

---

## Prompt

- `availableToolsResolver` ([#38](https://github.com/skepsik/utlas-ts/issues/38))
- Policy: search vs продлить блок; partial `blockTtl`; не копить TTL бесконечно

---

## Open questions

- `content` regex на v0?
- Новый search всегда новый `blockId`?
- `isBot` filter в query?
- Индексы на `messages`

---

## Out of scope

- Прямое чтение PG в обход visibility port
- `hasMedia` / `entityType` на v0
- Cross-chat, arbitrary SQL, semantic search, export всего чата

---
