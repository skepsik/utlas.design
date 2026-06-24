# LLM answer envelope

**Сейчас в wire:** `{ shouldReply, text }` + optional `conversationSettings.timezone` ([#39](https://github.com/skepsik/utlas-ts/issues/39), [#58](https://github.com/skepsik/utlas-ts/issues/58)).

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

  conversationSettings?: AnswerConversationSettings; // [conversation-settings](./conversation-settings.md)
  scratchpad?: Scratchpad; // [scratchpad](./scratchpad.md)
  blockTtl?: {
    blockId: string;
    ttlTurns: number;     // 0 = revoke
  }[];
};
```

`AnswerConversationSettings` — [conversation-settings](./conversation-settings.md).  
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

Wire schema для adapters: zod → `answer-json-schema.ts`; vendor-specific normalize (напр. Gemini `responseSchema`) — в адаптере, не в compose.

---

## Turn apply (порядок)

```text
1. tool loop по toolCalls (cap итераций) — [tools](../tools/index.md)
2. declarative patches (atomic): conversationSettings (timezone — в коде) → scratchpad → blockTtl
3. TTL tick всех active compose_blocks (один раз на завершённый user-turn)
4. deliver если `shouldReply` — иначе skip ([turn-pipeline](../turn-pipeline.md) § deliver)
```

Patches **до** deliver, в т.ч. при `shouldReply: false` ([#58](https://github.com/skepsik/utlas-ts/issues/58)).

---

## Prompt

- **Envelope:** PG `response_format` — JSON object, camelCase (без per-field policy).
- **Declare policy:** отдельные PG blocks + conditional resolvers, напр. `conversation_settings.timezone` ([#58](https://github.com/skepsik/utlas-ts/issues/58)); split `shouldReply` / `text` — [#59](https://github.com/skepsik/utlas-ts/issues/59).
- **Форма объекта** на wire — адаптер (`responseSchema`), не дублировать в system — [llm-jobs](./llm-jobs.md).
- Tools list — [tools](../tools/index.md) § Prompt.

Детали цепочки — [turn-prompt](../turn-prompt.md).

---

## Детали полей

| Поле | Страница |
|------|----------|
| `toolCalls` | [tools](../tools/index.md) · [geocode](../tools/geocode.md) · [message-search](../tools/message-search.md) |
| declarative snapshots | [declarative-snapshots](./declarative-snapshots.md) — хранение declare-снимков |
| `scratchpad` | [scratchpad](./scratchpad.md) — `kind: scratchpad` |
| `blockTtl` / compose blocks | [compose-blocks](./compose-blocks.md) |
| `conversationSettings` | [conversation-settings](./conversation-settings.md) |

---

## Later

- [ ] `toolCalls` + tool loop — [#38](https://github.com/skepsik/utlas-ts/issues/38)
- [ ] `scratchpad` — [scratchpad](./scratchpad.md)
- [ ] `blockTtl` + `compose_blocks` — [compose-blocks](./compose-blocks.md)
- [ ] Другие ключи `conversationSettings` — [conversation-settings](./conversation-settings.md)

- [ ] Parallel tool executor
- [ ] Nested `sideEffects` wrapper (если понадобится)
