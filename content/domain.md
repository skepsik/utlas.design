# Domain

Модель **human↔assistant**: qualifying ([transport](./transport.md)) → **turn** ([turn-pipeline](./turn-pipeline.md)) → ответ. Групповой чат — источник реплик; предмет домена — **anchor** (обращение к нашему binding), не социальный граф.

**`SemanticThread`** — семантическая ветка по **смыслу** вокруг anchor (не OS/TG thread, не синоним reply-chain).

---

## Глоссарий

| Термин              | Где в коде                               | Смысл                                                                                                                                                                                             |
| ------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **MessageRef**      | `@utlas/core/domain/model/message-ref`   | Одна реплика после ingress; атом хранения и envelope. Plain text — `body` / PG `text`; optional **`MessagePayload`** только для non-text (v0: `map_pin`) — [tools/composite](./tools/composite.md) § Память |
| **Anchor**          | `TurnRequest.anchor`                     | `MessageRef`, открывающий turn; центр **USER MESSAGE**                                                                                                                                            |
| **Conversation**    | `conversationId` + transport (composite) | Поток human↔assistant в одном messenger. v0: `conversationId` = TG `chat_id`; полная identity — `(transport, conversationId)` ([#30](https://github.com/skepsik/utlas-ts/issues/30))              |
| **Transport tag**   | `TurnRequest.transport`, `SelectContext.transport`, persist boundary | Канал доставки (`"telegram"`). **Не поле `MessageRef`** — свойство conversation / turn scope. PG: колонка `messages.transport` при persist. Prompt: `ctx.transport` ([#33](https://github.com/skepsik/utlas-ts/issues/33) ✅) |
| **Participant**     | `ParticipantRef`                         | Автор реплики                                                                                                                                                                                     |
| **Semantic thread** | `SemanticThread`                         | Семантическая ветка **по смыслу** вокруг anchor — utterances, отобранные эвристиками и (later) семантическим анализом. **Не** синоним reply-chain                                                 |
| **Recent messages** | `RecentMessages`                         | Хронологическое окно `MessageRef` перед anchor                                                                                                                                                    |
| **Turn**            | `TurnRequest` → `runTurn`                | **Скобка конкурентности**: один in-flight ответ на burst/anchor; supersede, cancel, deliver. Pipeline — [turn-pipeline](./turn-pipeline.md)                                                       |
| **Qualifying**      | `qualifiesForTurn`                       | Transport gate «это обращение к нам?» — **не** domain — [transport](./transport.md)                                                                                                               |
| **Owner**           | tenancy (later)                          | SaaS-клиент; **не** participant — [tenancy](./tenancy.md)                                                                                                                                         |
| **Assistant**       | —                                        | Разговорный термин; **entity в domain нет**                                                                                                                                                       |

Product voice — participant с `isBot` + binding; **role** (`our_voice`) — later.

**Reply-chain** (`anchorRef` walk) — transport-сигнал, сильный и механический; v0 selector `replyChain` — **первая реализация** slot SEMANTIC THREAD, не определение домена.

Термин **utterance** (open utterance / burst → **несколько** `MessageRef`) — later, отдельный контракт; в v0 не вводим.

---

## Domain layer

```
packages/core/src/
  domain/
    model/       MessageRef, ParticipantRef, MessageForward, AttributionRef,
                 SemanticThread, RecentMessages
    services/    buildSemanticThread, selectRecentBefore
    ports.ts     MessageReadPort, MessageSelector, SelectContext
```

**Правило:** `domain/` без SDK, ORM, grammY. Каталог — `@utlas/core`; см. [layout](./layout.md) § Monorepo.

### MessageRef

Одна реплика после ingress. **Не знает** turn, watermark, supersede, enrichment.

```ts
MessageRef {
  id: string
  conversationId: string
  sender: ParticipantRef
  sentAt: Date
  body: string
  anchorRef: string | null   // reply target (0..1) — transport signal
  quotedExcerpt: string | null
  links: string[]
  forward?: MessageForward
}
```

`created_at` ingest — только `messages.created_at`; в ref при read — fallback если `sent_at` пуст.

**Нет `transport`** — tag живёт на turn boundary (`TurnRequest.transport`) и в `SelectContext` при read; в PG — колонка `messages.transport` при `saveMessage`, не часть domain ref.

### Transport tag и Conversation

Transport — **свойство conversation**, не utterance. **Не denorm на `MessageRef`:** ingress передаёт tag в `saveMessage({ transport })` и в `TurnRequest.fromMessage({ transport })`; compose — `ctx.transport`. Composite identity `(transport, conversationId)` — [#30](https://github.com/skepsik/utlas-ts/issues/30). Boundary refactor — [#33](https://github.com/skepsik/utlas-ts/issues/33) ✅.

### ParticipantRef

```ts
{ key: string; label: string; isBot: boolean; handle?: string }
```

v0: `key = "tg:{user_id}"`.

### MessageForward + AttributionRef

```ts
MessageForward { from: AttributionRef; originAt?: Date }
AttributionRef { label: string; key?: string }
```

Ingress (TG): `parseForward` → persist → prompt `[forward from: …]` в `@utlas/core/llm/prompt/format.ts`.

### Context assembly → envelope

| # | Envelope block | Domain type | Service (v0) | Selector (v0) |
|---|----------------|-------------|--------------|----------------|
| 1 | **CHAT HISTORY** | `RecentMessages` | `selectRecentBefore` | `windowBefore(limit)` |
| 2 | **SEMANTIC THREAD** | `SemanticThread` | `buildSemanticThread` | `replyChain` ← transport signal |
| 3 | **USER MESSAGE** | anchor (+ `textOverride`) | — | — |

Оба wrapper — `{ messages: MessageRef[] }`. Prompt assembly — [turn-prompt](./turn-prompt.md).

### SemanticThread — замысел vs v0

**Замысел:** собрать реплики, **семантически** относящиеся к anchor (reply, open utterance, fork, deixis, …) — через `MessageSelector` registry и эвристики (`ThreadingProfile`, later LLM). Детали target-модели — [semantic-thread](./semantic-thread.md).

**v0:** selector `replyChain` — literal walk по `anchorRef`; совпадает с TG reply-chain. **Не путать** с доменным определением SemanticThread.

### MessageReadPort

```ts
MessageReadPort { selectors: { replyChain; windowBefore(limit) } }
SelectContext { anchor; transport }
```

См. [storage-mapping](./storage-mapping.md).

---

## Turn boundary

**Turn** — не «один вызов LLM», а **скобка конкурентности**: от qualifying anchor до deliver/cancel; burst supersede внутри gap.

```ts
TurnRequest { anchor; arity: DialogArity; outbound: OutboundPort; services; supersedeMaxGapMs; textOverride?; transport }
```

v0: monolith `runTurn` + `turn-state.ts` (module-global Map, supersede). Целевая механика — [turn-pipeline](./turn-pipeline.md).

```
enrichment → buildSemanticThread + selectRecentBefore → buildTurnPrompt → LlmRouter → egress
```

Qualifying + ingress/egress: [transport](./transport.md).

---

## Later

### ThreadingProfile

Профиль conversation для эвристик **SemanticThread** builder (voice vs forum vs chat). v0: `replyChain` selector.

---

## Scope

| In | Out |
|----|-----|
| `MessageRef`, participants, forward/quote | qualifying (transport) |
| `SemanticThread`, `RecentMessages`, read port | turn concurrency, LLM, egress |
| модель semantic thread (не = reply-chain) | social graph |
| | v0 literal `replyChain` как единственный selector |

---

## Open

- SemanticThread — selectors beyond `replyChain`; open utterance
- Owner vs tenant — sync с [tenancy](./tenancy.md)
- `ParticipantRef.role` vs `isBot`
- Chat settings — `bot_chats` per [tenancy](./tenancy.md)
- ThreadingProfile — контракт + storage
