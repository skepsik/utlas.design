# Message search

LLM tool `search_messages` — структурированный поиск по архиву сообщений чата. Модель передаёт **поисковый объект** (не SQL); backend компилирует в безопасный запрос.

Цель: поиск и пагинация **внутри множества, которое storage отдаёт как доступное** — когда в compose не влезает вся лента.

- Tool loop: [index](./index.md)
- Compose blocks / `blockTtl`: [compose-blocks](../envelope/compose-blocks.md)
- Journal (отдельно): [journal](../envelope/journal.md)

---

## Доступ — через port

Единственный путь чтения — **storage port** (`MessageReadPort` / visibility layer). Те же правила, что для context window.

- Search runner и hydrate ходят **только** через port.
- `/forget`, watermark — детали storage; tool не дублирует floor-логику.

---

## Tool surface (v0)

Имя: `search_messages`. Аргумент — `MessageSearchQuery`:

| # | Поле | Тип | Назначение |
|---|------|-----|------------|
| 1 | `content` | string | Текстовый поиск (substring v0) |
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

### `content`

- v0: **substring** (`ILIKE` / trgm later)
- later: regex с server-side caps

### Later (не v0)

- `hasMedia`, `entityType` — нужен persist / ingress metadata

---

## Ответ tool (в tool loop)

```ts
MessageSearchHit = { messageId, sentAt, userId, displayName, text, isReply, replyToMessageId? }

SearchToolResult = {
  blockId: string;
  hits: MessageSearchHit[];
  truncated: boolean;
}
```

Полные hits — для tool output в текущем turn. Блок в PG для последующих turn'ов — [compose-blocks](../envelope/compose-blocks.md).

---

## Инварианты

- **Scope**: `(transport, conversation_id)` текущего turn.
- **Visibility**: только через storage port.
- **Read-only** относительно `messages`.
- **Caps**: limit, hit text size on hydrate, max active blocks, max TTL.

---

## Размещение (ориентир)

```text
storage/message-search/       compile query, execute через port
storage/compose-blocks/       persist block, TTL
tools/runners/message-search/
turn/                         tool loop, apply blockTtl
llm/                          compose resolver: hydrate → inject
```

---

## Связь с context window

| Механизм | Что даёт |
|----------|----------|
| Visibility port | какие сообщения существуют для модели |
| Context window (compose) | недавняя лента (лимит N) |
| Journal | сжатые факты |
| Search tool | разовый запрос через port |
| Compose blocks | кэш `messageId` + hydrate; TTL via `blockTtl` |

---

## Prompt

- `availableToolsResolver` — [tools](./index.md)
- Policy: search vs продлить блок; partial `blockTtl`; не копить TTL бесконечно

---

## Open

- `content` regex на v0?
- Новый search всегда новый `blockId`?
- `isBot` filter в query?
- Индексы на `messages`

---

## Out of scope

- Прямое чтение PG в обход visibility port
- Cross-chat, arbitrary SQL, semantic search, export всего чата
