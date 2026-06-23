# Compose blocks

Кэш результатов tool'ов между turn'ами: модель создаёт блок через `toolCalls`, продлевает или revoke через top-level `blockTtl` в answer.

Envelope hub: [index](./index.md). Первый consumer — [message-search](../tools/message-search.md).

---

## Два канала (не смешивать)

| Канал | Когда | Что |
|-------|-------|-----|
| `toolCalls` → tool (e.g. `search_messages`) | tool loop (execute) | поиск + **создание** block; начальный `ttlTurns` в args |
| top-level `blockTtl` | финальный answer (declare) | **только** TTL patch / revoke `blockId` без нового tool call |

`blockTtl` **не** уходит в `toolCalls` (не synthetic tool). Sibling рядом с `journal`, `conversationSettings`.

---

## Модель блока

Блок — **кэш ссылок**, не снимок текста: в PG храним `messageId` (порядок сохраняем); актуальное содержимое — **hydrate on compose** через visibility port.

Несколько блоков от разных query могут coexist (`kind` различает тип).

### Хранение

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

При создании из tool result: `hit_message_ids` = ids из hits (текст в PG блока не дублируем).

---

## Hydrate on compose

1. Load блоков с `ttl_turns > 0`.
2. Для каждого `messageId` в `hit_message_ids` → `MessageReadPort` / visibility helper.
3. `null` / недоступно → skip (после `/forget` или сдвига watermark).
4. Собранные hits → секция в prompt; **пустой блок после hydrate** → не inject'ится.
5. Блок в PG не удаляем — visibility меняется на стороне port.

---

## TTL

- Начальный `ttlTurns` задаёт модель в args tool; backend clamp (`MAX_TTL_TURNS`).
- Декремент `ttl_turns` — **один раз на завершённый user-turn** ([turn-pipeline](../turn-pipeline.md)).
- `ttl_turns <= 0` → блок не в compose.

**Продление / revoke** — top-level `blockTtl`:

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

- Omit `blockTtl` → без изменений.
- `ttlTurns: 0` → revoke.
- Только перечисленные `blockId` обновляются.

Generic для любых `kind` (`message_search`, FTS, …); backend знает `kind` по PG.

---

## Отличие от journal

[journal](./journal.md) — сжатая память модели (full replace в answer). Compose blocks — кэш `messageId` + hydrate для prompt.

---

## Размещение (ориентир)

```text
storage/compose-blocks/     persist, TTL tick, apply blockTtl
turn/                       apply blockTtl from answer; TTL decrement
llm/                        compose resolver: load → hydrate → inject
```

---

## Open

- Новый search всегда новый `blockId`?
- Max active blocks / max TTL caps
