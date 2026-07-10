# Storage mapping

MessageRef ↔ Postgres. Domain types — [domain](./domain/). Conversation identity (uuid, `external_key`, `dialogArity`) — [#81](https://github.com/skepsik/utlas-ts/issues/81).

---

## Модули и subpath exports ([#94](https://github.com/skepsik/utlas-ts/issues/94))

Физическая укладка = npm subpath. Barrel `@utlas/core/storage` — backward-compat superset; новый код предпочитает subpath.

| Subpath | Папка | Ответственность |
|---------|-------|-----------------|
| `@utlas/core/storage/messages` | `messages/` | `saveMessage`, `updateMessageText`, `getMessage` |
| `@utlas/core/storage/conversations` | `conversations/` | resolve, record, writes, patch, WireStore |
| `@utlas/core/storage/audit` | `audit/` | `logLlmCall`, `logGenerationFailure` |
| `@utlas/core/storage/llm-config` | `llm-config/` | execution strategy port, prompt blocks, seeds (subpath) |
| `@utlas/core/storage/context-read` | `context-read/` | `PostgresContextRead`, selectors, watermark |
| `@utlas/core/storage/postgres` | `postgres/` | client, Drizzle schema (tests / internal) |

`patchConversationByExternalKey` и прочие internal UPSERT primitives — через `conversations/` subpath, не обязательны в main barrel.

---

## ConversationWireStore ([#98](https://github.com/skepsik/utlas-ts/issues/98), [#99](https://github.com/skepsik/utlas-ts/issues/99))

Binding-scoped фасад: `transport` инжектится один раз в `createConversationWireStore(pg, transport)`; методы без повтора tag на call site.

| Метод | Делегат |
|-------|---------|
| `ensure` | `ensureConversation` |
| `getMemberCount` | `getMemberCount` |
| `syncMembership` | `updateConversationMembershipInfoByKeys` |
| `patchSettings` | `patchConversationByExternalKey` |
| `resetContext` | `resetConversationContext` |
| `getRecord` | `getConversationRecord` |
| `getExternalKey` | `getConversationExternalKey` (без `transport` в ответе) |

**Transport boundary:** handlers держат `ConversationWireStore` + `TelegramMembershipResolver` в deps ([transport/telegram](./transport/telegram.md)); не hub storage и не прямые UPSERT в listeners. Composition root создаёт один store на transport instance.

Low-level `ensureConversation` / `updateBotEnabled` / … остаются в barrel для turn paths и тестов; transport-код v0 — через store.

**Later:** `saveMessage` через store — optional ([#99](https://github.com/skepsik/utlas-ts/issues/99) out of scope).

---

## OutboundConversation ([#97](https://github.com/skepsik/utlas-ts/issues/97))

Egress DTO для одного `OutboundPort.deliver` — **не** PG mapping. Тип `OutboundConversation` — `transport/types/outbound-port.ts`; builder `outboundConversation()` — `transport/outbound-conversation.ts`; не в storage.

См. [transport](./transport/index.md) § OutboundContext.

---

## Read paths

| Path | API | Когда |
|------|-----|-------|
| Raw row by transport + keys | `getMessage(pg, transport, conversationId, messageId)` | edits, point lookups |
| Context assembly | `PostgresContextRead` (`MessageReadPort`) + watermark (`getContextResetFloor`) | turn prompt, semantic thread |

`getMessage` не применяет watermark; `PostgresContextRead` — floor и selectors. Оба — `@utlas/core/storage`.

---

## Multi-transport

Wire identity: `(transport, external_key)` — `UNIQUE` в PG. Канон значений tag — `TransportTag` в `packages/core/src/domain/model/transport-tag.ts` (`TransportTag.telegram`, …). Factory: `createConversationWireStore(pg, TransportTag.telegram)` — не локальные литералы на call sites.

**Не сейчас:** несколько bot instance на одном transport tag — [tenancy](./tenancy.md).

---

## Типы conversation (терминология)

Три оси — **не** вводить umbrella `ConversationSettings`:

| Тип | Ось | Примеры полей |
|-----|-----|----------------|
| `ConversationUserSettings` | tunables (/settings, model declare) | `botEnabled`, `debugMode`, `contextLimitOverride`, `timezone` |
| `ConversationRecord` | PG row read model | + `title`, `transport`, `memberCount`, timestamps |
| `MembershipInfo` | arity для turn/qualify/prompt | `wireArity`, `memberCount` → `dialogArity` getter |

Row meta (`title`, denorm `member_count`) — **не** «settings» в UX смысле. Split read-model без `title` на transport — follow-up, не #94.

---

## Class vs function

| Class | Function |
|-------|----------|
| `ConversationWireStore`, `TelegramMembershipResolver` | codecs (`encodeTelegramConversationKey`), row mappers, DTO builders |
| `PostgresContextRead` (port impl) | `outboundConversation()`, `patchConversationByExternalKey` |
| `MembershipInfo` (VO с инвариантом) | thin UPSERT wrappers в `writes.ts` |

DTO / Record types — **не** class. Transport class policy — [#88](https://github.com/skepsik/utlas-ts/issues/88).

---

## `conversations` ([#81](https://github.com/skepsik/utlas-ts/issues/81))

Атом разговора и per-conversation settings. PK — `id uuid`; wire identity — `(transport, external_key)`.

| Поле (TS / read) | PG | Примечание |
|------------------|-----|------------|
| `conversationId` | `id` | uuid; FK из `messages`, `llm_calls`, `generation_failures` |
| — | `transport` | `"telegram"`, … |
| — | `external_key` | Transport wire key; `UNIQUE(transport, external_key)` |
| `dialogArity` | `dialog_arity` | effective arity при write (`MembershipInfo.dialogArity`); denorm вместе с `member_count` |
| — | `member_count` | denorm: chat-level + topic rows, существовавшие на момент write; источник — `members.ts` / `initMemberCount` |
| — | `member_count_updated_at` | при write non-null count |
| `botEnabled`, `debugMode`, `contextLimitOverride`, `timezone`, `title` | same | см. [conversation-settings](./envelope/conversation-settings.md) |
| — | `context_reset_after_message_id`, `context_reset_at` | `/forget` watermark |

Resolve/create (low-level): `ensureConversation(pg, transport, externalKey, meta?)` → uuid.  
Transport v0: `ConversationWireStore.ensure(externalKey, …)` — тот же UPSERT, tag из store.

Per-row read (settings, prompt): `getConversationRecord` / `store.getRecord(conversationId)` — **без** `dialogArity`; turn/qualify берут `MembershipInfo` с transport boundary.

Forum topic — отдельная row (`external_key` с `:t{thread_id}`). **Write:** `store.syncMembership` / `updateConversationMembershipInfoByKeys` на chat-level + все topic keys в PG на момент write; topic, созданный позже, может временно иметь `null` до member-event или `initMemberCount` backfill. **Turn read:** chat-level через `TelegramMembershipResolver.forChat`, не topic-row. Explorer view `explorer_conversations` — `COALESCE` с chat-level для UI.

---

## MessageRef ↔ `messages`

| Поле `MessageRef` | PG `messages` | Примечание |
|-------------------|-----------------|------------|
| `conversationId` | `conversation_id` | uuid → `conversations.id` |
| `id` | `message_id` | |
| `sender.key` | `user_id` | prefix `tg:` только в domain |
| `sender.label` | `display_name` | |
| `sender.handle` | `username` | |
| `sender.isBot` | `is_bot` | |
| `anchorRef` | `reply_to_message_id` | transport signal |
| `quotedExcerpt` | `quoted_text` | `quote_position` — transport-only |
| `body` | `text` | plain text; PG `type` null |
| `payload?.type` | `type` | `NULL` или `points` \| `places` — SQL-фильтр |
| `payload` (поля) | `payload` jsonb | поля варианта без discriminant; storage ↔ domain — [message-payload](./domain/message-payload.md) |
| `sentAt` | `sent_at` | UTC `YYYY-MM-DD HH:mm:ss` |
| `forward.from.label` | `forward_from` | |
| `forward.originAt` | `forward_origin_at` | |

**Не на `MessageRef`:** `transport` — колонка PG `messages.transport`; задаётся при `saveMessage({ ref, transport })` и при read (`getMessage(transport, …)`, `SelectContext.transport`). `rowToRef` не мапит transport в ref.

Conversation settings / watermark: `conversations` по uuid; wire lookup — `(transport, external_key)`. Multi-bot — [tenancy](./tenancy.md) (`bot_chats` later).

Storage key: `(conversation_id, message_id)`; `messages.transport` — denorm для read/filter.

Impl read port: `PostgresContextRead` (work [#26](https://github.com/skepsik/utlas-ts/issues/26) closed).

---

## `generation_failures` ([#78](https://github.com/skepsik/utlas-ts/issues/78))

Turn/generation **incidents** — не substitute для `llm_calls` (invoke audit). Политика egress — [transport](./transport/) § Generation failures.

| Поле (TS / domain) | PG | Примечание |
|--------------------|-----|------------|
| `conversationId` | `conversation_id` | uuid → `conversations.id` |
| `transport` | `transport` | |
| `triggerMessageId` | `trigger_message_id` | anchor turn |
| `phase` | `phase` | `llm` \| `tool` \| `egress` \| `settings` \| `other` |
| `errorText` | `error_text` | `briefErrorText(err)` |
| `httpCode` | `http_code` | nullable |
| `createdAt` | `created_at` | default `now()` |

Insert: `logGenerationFailure(pg, …)` в `@utlas/core/storage/generation-failures`; wiring через `TurnServices.logGenerationFailure` (`main.ts`).
