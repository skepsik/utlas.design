# Transport

**Transport layer** — доставка human↔assistant через messengers: ingress, qualifying, egress. Один мессенджer = подпапка `transport/<name>/`; SDK и event wiring **только** там.

Домен ([domain](./domain.md)) agnostic: `MessageRef`, turn. Transport нормализует сырой event → `MessageRef` и обратно.

**Статус:** v0 Telegram — **сверено с кодом** (2026-06).

---

## Термины

| Термин | Смысл |
|--------|--------|
| **Ingress** | Сырой event → `MessageRef` → persist. Quote, forward, reply, `sentAt`, participant — здесь. |
| **Egress** | Ответ наружу: send reply, формат (HTML), threading (`reply_parameters`). Turn знает только `ReplySender`. |
| **Qualifying** | «Это обращение к **нашему** binding?» — transport-specific, **до** `runTurn`. |
| **Transport** | Ingress + qualifying + egress + wiring для одного мессенджера. |

Ingress = трафик в систему, egress = из системы.

---

## Зачем `transport/`, а не SDK в корне

- Один мессенджer = одна подпапка; снаружи — `createTelegramBot` / registry.
- Новый transport — новая папка + регистрация; domain/turn/storage не трогаем.
- Правило: **grammY (и любой messenger SDK) только под `transport/telegram/`**.

---

## Дерево (as implemented)

```
transport/
  base.ts                 ReplySender, Transport, IngressResult
  turn-qualification.ts   TurnQualification + TurnQualificationFactory
  factory.ts              createTransport (type guard)
  registry.ts             TransportRegistry
  index.ts

  telegram/
    bot.ts                createTelegramBot → Transport
    handlers.ts           grammY wiring: commands + message handler
    ingress.ts            tgMessageToRef, persistIngress
    forward.ts            parseQuote, parseForward, parseForwardLabel
    trigger.ts            qualifiesForTurn, shouldRespondInGroup
    egress.ts             createReplySender, telegramReplyTo, markdown chunk
    format.ts             markdownToTelegramHtml
    edits.ts              edited_message → updateMessageText
    settings.ts           /settings → chats table
    texts.ts, constants.ts
    index.ts              re-exports
```

**Вне transport/** (agnostic): `domain/`, `storage/`, `turn/`, `enrichment/`, `llm/`, `clients/`, `orchestrator/`, `main.ts`.

---

## Ports (`transport/base.ts`)

### ReplySender

```ts
ReplySender {
  sendReply({ chatId, replyToMessageId?, text }): Promise<SentMessage>
  saveBotReply({ chatId, anchorMessageId, text, sent }): Promise<MessageRef>
}
```

Impl: `createReplySender({ api, pg })` в `telegram/egress.ts`. Turn вызывает `sendReply` + `saveBotReply`; grammY не импортирует.

### Transport

```ts
Transport { type: string; start(): Promise<void>; stop(): Promise<void> }
```

Impl: `createTelegramBot(...)` — регистрирует handlers, возвращает `{ type: "telegram", start, stop }`.

### TurnQualification (`transport/turn-qualification.ts`)

Boundary type для qualifying — **не** domain entity:

```ts
| { qualifies: true; via: "private" | "mention" | "reply_to_bot" }
| { qualifies: false; reason: "not_for_bot" | "bot_off" | "command" }
```

Factory: `TurnQualificationFactory.qualified / .rejected`.

**v0:** `qualifiesForTurn` возвращает `private | mention | reply_to_bot | not_for_bot`.  
`bot_off` — зарезервирован; **`bot_enabled` проверяется в `runTurn`**, не в trigger.

---

## Telegram — handler flow

```
grammY update
  ├─ /settings     → settings.ts (chats table, без turn)
  ├─ /forget       → resetChatContext + reply
  ├─ /ask          → persistIngress → TurnRequest.fromAsk → runTurn
  ├─ edited_message → updateMessageText (edits.ts)
  └─ message       → persistIngress
                       → qualifiesForTurn?
                       → TurnRequest.fromMessage → runTurn
```

**Persist всегда до gate** — сообщения без qualifying тоже сохраняются (parity Python).

**Команды с `/`** в generic handler пропускаются (`message.text?.startsWith("/")`).

### Ingress (`ingress.ts` + `forward.ts`)

- `tgMessageToRef(message, textOverride?)` → `MessageRef | null`
  - skip: нет `from`, пустой body без quote
  - `sentAt` из `message.date` (UTC)
  - `anchorRef` из `reply_to_message.message_id`
  - `forward` через `parseForward` → `MessageForward`
  - `quotedExcerpt` через `parseQuote`
  - `links` — regex URL из текста
- `persistIngress` → `saveMessage({ ref, transport: TELEGRAM_TAG, … })` + `quotedText`, `quotePosition`, `replyToMessageId`; transport **не** на `MessageRef` ([domain](./domain.md))

### Qualifying (`trigger.ts`)

| Условие | `via` |
|---------|-------|
| `chat.type === "private"` | `private` |
| reply на сообщение бота (group) | `reply_to_bot` |
| `@mention` бота в entities | `mention` |
| иначе | reject `not_for_bot` |

`/ask` — **обходит** qualifying (явный вызов).

### Egress (`egress.ts` + `format.ts`)

- `markdownToTelegramHtml` → `parse_mode: "HTML"`; fallback plain text при ошибке API
- длинные ответы — chunk по 4096
- `reply_parameters.message_id` когда `replyToMessageId` задан
- `saveBotReply` — persist исходящего с `sender.isBot`, `anchorRef` = trigger

**Threading policy** (`telegramReplyTo` / `replyToForAnchor` в turn):

- private без reply на trigger → без `reply_parameters`
- иначе → reply на `anchor.id`

### Message lifecycle: edit / delete (2026-06, decided)

Transport отвечает только за **синхронизацию PG с тем, что мессенджer сообщил**. Turn/LLM — отдельно.

| Событие | Telegram v0 | Политика |
|---------|-------------|----------|
| **Edit** (`edited_message`) | ✅ приходит | `edits.ts` → `updateMessageText`: обновить **только** `messages.text`. Quote / forward / reply / `sentAt` **не** пересчитывать (parity `edit_handlers.py`). **Без** `runTurn`. |
| **Edit → пусто** (текст и caption сняты) | ✅ как edit | Считать **очисткой контента**, не delete row: persist `text = ""`. *(Сейчас skip — stale; small fix в transport.)* |
| **Delete** (сообщение исчезло без edit) | ❌ Bot API не шлёт update в private/group | Row в PG **не удалять** — last-known snapshot. Reply-chain и `llm_calls` ссылаются на `message_id`. |
| **Delete** (другие transport / Business API) | later | Опционально `deleted_at` + tombstone; row по-прежнему не DELETE. |

**Не делаем на transport:**

- hard `DELETE` из `messages`
- regen ответа бота при edit — **turn** (parity `turn_handlers.on_edited_message_llm`; в TS **нет**, later)

**Принцип:** PG — append-only archive по `(transport, chat_id, message_id)`; transport правит только поля, которые реально пришли в update.

---

## Transport tag на boundary

Transport tag — conversation scope, не utterance. Ingress: `TELEGRAM_TAG` в `saveMessage` и `TurnRequest.fromMessage({ transport })`; prompt — `ctx.transport`. **Не поле `MessageRef`.** [#33](https://github.com/skepsik/utlas-ts/issues/33) ✅. Hub: [domain](./domain.md) § Transport tag.

## Стык с turn

```ts
TurnRequest.fromMessage({ anchor, arity, replySender, services, supersedeMaxGapMs, transport })
TurnRequest.fromAsk({ ... , text, transport })  // textOverride для USER MESSAGE
```

Turn pipeline **не** импортирует grammY. Egress только через `ReplySender` на request.

Composition root (`main.ts`): `createTelegramBot` + `TransportRegistry.register`; `turnServices.messageReadPort = PostgresContextRead`.

---

## Enrichment

**v0:** `runEnrichment` в `runTurn` (turn-hook), не ingress transform.

Ingress transform chain (`enrichment → capture`) — later; см. enrichment registry.

---

## Transport ≠ connectors

| | Transport | Clients |
|---|-----------|------------|
| Назначение | Messengers: ingress / egress | Внешние API (Obsidian, Jira, …) |
| Registry | `TransportRegistry` | `ClientRegistry` |
| Domain | `MessageRef` in/out | bindings, orchestrator steps |

**Git deploy** — `infra/`, не connector.

---

## Тесты (v0)

`test/transport-telegram.test.ts`:

- `parseQuote`, `parseForward`, `parseForwardLabel`
- `tgMessageToRef` (quote-only, forward)
- `qualifiesForTurn` / `shouldRespondInGroup` (private, mention, reply, reject)

---

## Parity checklist (TS)

- [x] `transport/telegram/`; grammY только там
- [x] Ingress: text, quote, forward, reply, links, persist
- [x] Qualifying: private / @mention / reply_to_bot
- [x] `/ask`, `/forget`, `/settings`
- [x] Egress: HTML, chunk, reply threading, saveBotReply
- [x] `edited_message` → update text in PG (см. § Message lifecycle)
- [x] Delete policy: no row DELETE; Telegram delete N/A v0
- [x] `ReplySender` port; turn без SDK import
- [x] `TurnQualification` boundary type
- [ ] Ingress transform (STT / enrichment pre-capture) — later
- [ ] Media / caption-only без текста — по мере parity
- [x] `telegramReplyTo` vs `replyToForAnchor` — dedupe ([#29](https://github.com/skepsik/utlas-ts/issues/29))

---

## Open

- [ ] **`bot_off` в TurnQualification** — перенести check из `runTurn` в trigger или убрать из type
- [x] **Dedupe** `telegramReplyTo` / `replyToForAnchor` → `turn/reply-to-anchor.ts` ([#29](https://github.com/skepsik/utlas-ts/issues/29))
- [x] **Transport boundary** — transport на `TurnRequest` / persist, не на `MessageRef` ([#33](https://github.com/skepsik/utlas-ts/issues/33))
- [ ] **Second transport** — шаблон подпапки + registry factory
- [ ] **Ingress enrichment** — hook до `persistIngress`
- [ ] **Multi-bot** — qualifying на self binding per [tenancy](./tenancy.md)
- [ ] **Empty edit → `text=""`** — transport (`edits.ts`), parity intent
- [ ] **LLM regen on edit** — turn (parity `turn_handlers`), не transport

---
