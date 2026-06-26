# Storage mapping

MessageRef ↔ Postgres. Domain types — [domain](./domain.md).

---

## MessageRef ↔ `messages`

| Поле `MessageRef` | PG `messages` | Примечание |
|-------------------|-----------------|------------|
| `conversationId` | `conversation_id` | |
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

Conversation settings / watermark: `conversations` per `(transport, conversation_id)` — [tenancy](./tenancy.md) (`bot_chats` later).

Storage key: `(transport, conversation_id, message_id)`.

Impl read port: `PostgresContextRead` (work [#26](https://github.com/skepsik/utlas-ts/issues/26) closed).

---

## `generation_failures` ([#78](https://github.com/skepsik/utlas-ts/issues/78))

Turn/generation **incidents** — не substitute для `llm_calls` (invoke audit). Политика egress — [transport](./transport.md) § Generation failures.

| Поле (TS / domain) | PG | Примечание |
|--------------------|-----|------------|
| `conversationId` | `conversation_id` | |
| `transport` | `transport` | |
| `triggerMessageId` | `trigger_message_id` | anchor turn |
| `phase` | `phase` | `llm` \| `tool` \| `egress` \| `settings` \| `other` |
| `errorText` | `error_text` | `briefErrorText(err)` |
| `httpCode` | `http_code` | nullable |
| `createdAt` | `created_at` | default `now()` |

Insert: `logGenerationFailure(pg, …)` в `@utlas/core/storage/generation-failures`; wiring через `TurnServices.logGenerationFailure` (`main.ts`).
