# LLM answer envelope

**Сейчас:** `{ shouldReply, text }` — [#39](https://github.com/skepsik/utlas-ts/issues/39).

---

## Зачем

Единый JSON-контракт на каждый inference-ответ модели (**camelCase** на wire, structured output на adapter):

- не ветвить adapter/turn между plain text и structured path;
- `shouldReply` и `text` — обязательные поля каждого ответа;
- execute (tools) и declare (patches) в одном объекте, но **разные фазы** turn.

---

## Answer envelope (canonical)

Модель **всегда** возвращает JSON object (`LlmAnswer`). Optional-поля: **omit** = без изменений.

### Полная схема (target)

```ts
type LlmAnswer = {
  shouldReply: boolean;
  text: string;

  toolCalls?: ToolCall[];

  conversationSettings?: {
    timezone?: string;    // IANA; validate server-side — [#48](https://github.com/skepsik/utlas-ts/issues/48)
  };
  scratchpad?: Scratchpad; // [scratchpad](./scratchpad.md)
  blockTtl?: {
    blockId: string;
    ttlTurns: number;     // 0 = revoke
  }[];
};
```

`Scratchpad` — [scratchpad](./scratchpad.md).

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

### Две фазы (не смешивать)

| Фаза | Поля | Семантика |
|------|------|-----------|
| **Execute** (tool loop) | `toolCalls?` | imperative: backend **выполняет** runners — [tools](../tools/index.md) |
| **Declare** (после loop, до egress) | `scratchpad?`, `blockTtl?`, `conversationSettings?` | declarative patch: **ничего не execute**, только apply к storage |

Nested wrapper (`sideEffects`) — **не сейчас**; top-level siblings. Группировку можно добавить позже.

### Создание vs TTL compose-blocks

| Действие | Канал |
|----------|--------|
| Найти / создать блок (search, FTS, …) | `toolCalls` → tool; начальный `ttlTurns` в args — [tools](../tools/message-search.md) |
| Продлить / revoke существующий `blockId` | top-level `blockTtl` — [compose-blocks](./compose-blocks.md) |

`blockTtl` **не** synthetic tool в `toolCalls`.

---

## Parse и validator

Источник правды в коде — **zod** (`packages/core/src/llm/answer.ts`, `parse-answer.ts`).

- `.strict()` на корне; каждое новое optional-поле — отдельный work-issue + apply handler.
- **Parse fail / invalid schema** → fallback `shouldReply: true`, `text` = trimmed raw + log.
- Declarative patches — **best-effort**: битый `scratchpad` ≠ не слать `text`.

Wire schema для adapters: `zod-to-json-schema` (`answer-json-schema.ts`).

---

## Turn apply (порядок)

```text
1. tool loop по toolCalls (cap итераций) — [tools](../tools/index.md)
2. declarative patches (atomic): conversationSettings → scratchpad → blockTtl
3. TTL tick всех active compose_blocks (один раз на завершённый user-turn)
4. deliver если `shouldReply` — иначе skip ([turn-pipeline](../turn-pipeline.md) § deliver)
```

---

## Prompt

PG block `response_format` — формат JSON + optional-поля по мере реализации. Список tools — [tools](../tools/index.md) § Prompt.

---

## Детали полей

| Поле | Страница |
|------|----------|
| `toolCalls` | [tools](../tools/index.md) · [geocode](../tools/geocode.md) · [message-search](../tools/message-search.md) |
| declarative snapshots | [declarative-snapshots](./declarative-snapshots.md) — хранение declare-снимков |
| `scratchpad` | [scratchpad](./scratchpad.md) — `kind: scratchpad` |
| `blockTtl` / compose blocks | [compose-blocks](./compose-blocks.md) |
| `conversationSettings.timezone` | [#48](https://github.com/skepsik/utlas-ts/issues/48) (work) |

---

## Цель

- [ ] `toolCalls` + tool loop — [#38](https://github.com/skepsik/utlas-ts/issues/38)
- [ ] `scratchpad` — [scratchpad](./scratchpad.md)
- [ ] `blockTtl` + `compose_blocks` — [compose-blocks](./compose-blocks.md)
- [ ] `conversationSettings.timezone` — [#48](https://github.com/skepsik/utlas-ts/issues/48)

## Later

- [ ] Parallel tool executor
- [ ] Nested `sideEffects` wrapper (если понадобится)
