# Storage mapping

MessageRef ↔ Postgres. Domain types — [domain](./domain.md). Conversation identity (uuid, `external_key`, `dialogArity`) — [#81](https://github.com/skepsik/utlas-ts/issues/81).

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

Resolve/create: `ensureConversation(pg, transport, externalKey, meta?)` → uuid.  
Per-row read (settings, prompt): `getConversationRecord(pg, conversationId)` — **без** `dialogArity`; turn/qualify берут `MembershipInfo` с transport boundary.

Forum topic — отдельная row (`external_key` с `:t{thread_id}`). **Write:** `updateConversationMembershipInfoByKeys` на chat-level + все topic keys в PG на момент write; topic, созданный позже, может временно иметь `null` до member-event или `initMemberCount` backfill. **Turn read:** chat-level через `telegramChatMembershipInfo`, не topic-row. Explorer view `explorer_conversations` — `COALESCE` с chat-level для UI.

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
| `body` | `text` | plain text; `kind` null |
| `kind` | `kind` | `NULL` или `map_pin`, later `document`, … — SQL-фильтр |
| `payload` | `payload` jsonb | поля варианта без `kind`; storage ↔ domain — [composite](./tools/composite.md) |
| `sentAt` | `sent_at` | UTC `YYYY-MM-DD HH:mm:ss` |
| `forward.from.label` | `forward_from` | |
| `forward.originAt` | `forward_origin_at` | |

**Не на `MessageRef`:** `transport` — колонка PG `messages.transport`; задаётся при `saveMessage({ ref, transport })` и при read (`getMessage(transport, …)`, `SelectContext.transport`). `rowToRef` не мапит transport в ref.

Conversation settings / watermark: `conversations` по uuid; wire lookup — `(transport, external_key)`. Multi-bot — [tenancy](./tenancy.md) (`bot_chats` later).

Storage key: `(conversation_id, message_id)`; `messages.transport` — denorm для read/filter.

Impl read port: `PostgresContextRead` (work [#26](https://github.com/skepsik/utlas-ts/issues/26) closed).

---

## `generation_failures` ([#78](https://github.com/skepsik/utlas-ts/issues/78))

Turn/generation **incidents** — не substitute для `llm_calls` (invoke audit). Политика egress — [transport](./transport.md) § Generation failures.

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
