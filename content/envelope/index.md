# LLM answer envelope

**Реализовано (work):** базовый envelope `{ shouldReply, text }` — [#39](https://github.com/skepsik/utlas-ts/issues/39) ✅. Расширения ниже — open.

---

## Зачем

Единый JSON-контракт на каждый inference-ответ модели (camelCase, structured output на adapter):

- не ветвить adapter/turn между plain text и structured path;
- `shouldReply` до tool loop и egress;
- execute (tools) и declare (patches) в одном объекте, но **разные фазы** turn.

---

## Answer envelope (canonical)

Модель **всегда** возвращает JSON object. Optional-поля: **omit** = без изменений.

### Две фазы (не смешивать)

| Фаза | Поля | Семантика |
|------|------|-----------|
| **Execute** (tool loop) | `toolCalls?` | imperative: backend **выполняет** runners — [tools](../tools/index.md) |
| **Declare** (после loop, до egress) | `journal?`, `blockTtl?`, `conversationSettings?` | declarative patch: **ничего не execute**, только apply к storage |

Nested wrapper (`sideEffects`) — **не сейчас**; top-level siblings. Группировку можно добавить позже.

### Полная схема (target)

```ts
type LlmAnswer = {
  shouldReply: boolean;   // false → turn не шлёт deliver
  text: string;           // тело для пользователя; "" если shouldReply false

  toolCalls?: ToolCall[]; // execute в loop; v0 sequential; later parallel deps

  conversationSettings?: {
    timezone?: string;    // IANA; validate server-side — [#48](https://github.com/skepsik/utlas-ts/issues/48)
  };
  journal?: unknown;      // full replace; omit = unchanged — [journal](./journal.md)
  blockTtl?: {             // TTL patch compose-blocks; omit = unchanged
    blockId: string;
    ttlTurns: number;     // 0 = revoke
  }[];
};
```

### Создание vs TTL compose-blocks

| Действие | Канал |
|----------|--------|
| Найти / создать блок (search, FTS, …) | `toolCalls` → tool; начальный `ttlTurns` в args — [tools](../tools/message-search.md) |
| Продлить / revoke существующий `blockId` | top-level `blockTtl` — [compose-blocks](./compose-blocks.md) |

`blockTtl` **не** synthetic tool в `toolCalls`.

### Примеры

```json
{ "shouldReply": true, "text": "Привет!" }
```

```json
{
  "shouldReply": true,
  "text": "Запомнил.",
  "conversationSettings": { "timezone": "Europe/Moscow" }
}
```

```json
{
  "shouldReply": true,
  "text": "…",
  "toolCalls": [
    { "name": "search_messages", "arguments": { "content": "дедлайн", "ttlTurns": 5 } }
  ]
}
```

```json
{
  "shouldReply": true,
  "text": "…",
  "blockTtl": [
    { "blockId": "abc-123", "ttlTurns": 3 },
    { "blockId": "def-456", "ttlTurns": 0 }
  ]
}
```

---

## Parse и validator

Источник правды в коде — **zod** (`packages/core/src/llm/answer.ts`, `parse-answer.ts`).

- `.strict()` на корне; каждое новое optional-поле — отдельный work-issue + apply handler.
- **Parse fail / invalid schema** → fallback `shouldReply: true`, `text` = trimmed raw + log ([turn-pipeline](../turn-pipeline.md)).
- Declarative patches — **best-effort**: битый `journal` ≠ не слать `text`.

Wire schema для adapters: `zod-to-json-schema` (`answer-json-schema.ts`).

---

## Turn apply (порядок)

```text
1. tool loop по toolCalls (cap итераций) — [tools](../tools/index.md)
2. declarative patches (atomic): conversationSettings → journal → blockTtl
3. TTL tick всех active compose_blocks (один раз на завершённый user-turn)
4. egress если shouldReply
```

---

## Prompt

PG block `response_format` — формат JSON + optional-поля по мере реализации. Список tools — [tools](../tools/index.md) § Prompt.

---

## Детали полей

| Поле | Страница |
|------|----------|
| `toolCalls` | [tools](../tools/index.md) · [geocode](../tools/geocode.md) · [message-search](../tools/message-search.md) |
| `journal` | [journal](./journal.md) |
| `blockTtl` / compose blocks | [compose-blocks](./compose-blocks.md) |
| `conversationSettings.timezone` | [#48](https://github.com/skepsik/utlas-ts/issues/48) (work) |

---

## Open

- [ ] `toolCalls` + tool loop — [#38](https://github.com/skepsik/utlas-ts/issues/38)
- [ ] `journal` — [journal](./journal.md)
- [ ] `blockTtl` + `compose_blocks` — [compose-blocks](./compose-blocks.md)
- [ ] `conversationSettings.timezone` — [#48](https://github.com/skepsik/utlas-ts/issues/48)
- [ ] Parallel tool executor (later)
- [ ] Nested `sideEffects` wrapper (later, if needed)
