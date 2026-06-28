# Transport

**Transport layer** — доставка human↔assistant через messengers: ingress, qualifying, egress. Один мессенджer = подпапка `transport/<name>/`; SDK и event wiring **только** там.

Домен ([domain](./domain.md)) agnostic: `MessageRef`, turn. Transport нормализует сырой event → `MessageRef` и обратно.

**Сейчас:** Telegram v0 — [checklist](#v0-checklist) ниже. Conversation identity (uuid + `external_key`, forum topics, `dialogArity`, member events) — [#81](https://github.com/skepsik/utlas-ts/issues/81).

---

## Conversation identity ([#81](https://github.com/skepsik/utlas-ts/issues/81))

**Атом разговора** — `conversations.id` (uuid). Domain / turn / storage видят только uuid в `MessageRef.conversationId`. Transport склеивает wire key в `external_key`; decode обратно — только в `transport/telegram/`.

### `external_key` (Telegram)

| Случай | `external_key` | Пример |
|--------|----------------|--------|
| Любой чат без forum thread | `tg:{chat_id}` | `tg:-100123` |
| Forum topic (не General) | `tg:{chat_id}:t{thread_id}` | `tg:-100123:t42` |
| General (`message_thread_id === 1`) | без суффикса | `tg:-100123` |

Encode: `encodeTelegramConversationKey(chatId, messageThreadId?)`. Decode: `decodeTelegramConversationKey` → `{ chatId, messageThreadId? }`. Egress: `telegramWireTarget(pg, conversationId)` по uuid.

**Ingress:** `Message` → `external_key` + `conversationRowTitlePartialFromChat` → `ensureConversation` → `saveMessage`.  
**Commands / egress:** тот же локальный resolve; `getConversationRecord` для user settings; `telegramChatMembershipInfo` для `MembershipInfo` / qualifying.

Forum topic = **отдельная** row в `conversations` (свой uuid, watermark, settings). **`member_count` и `dialog_arity` — denorm на chat-level и на topic rows**, которые уже есть в PG на момент write (`writeTelegramMemberCount` → `updateConversationMembershipInfoByKeys`). Новый topic-row после write остаётся с `null`, пока не сработает member-event или `initMemberCount` (backfill с chat-level, без API).

**Qualifying / turn read:** всегда chat-level — `telegramChatMembershipInfo(pg, chat)` → `MembershipInfo` → `dialogArity` getter. Topic-row count/arity для turn **не** читаются.

### Маппинг Chat → row (не «meta»)

Transport — однонаправленный поток событий; **без hub'ов** и без optional `api` на message path.

| Слой | Имя | Роль |
|------|-----|------|
| transport | `telegramChatTitle(chat)` | title из grammY `Chat` |
| transport | `conversationRowTitlePartialFromChat(chat)` | `{ title? }` для upsert |
| storage | `ConversationRowTitlePartial` | chat-known поля на upsert (`title?`) |
| storage | `ensureConversation(pg, transport, externalKey, patch?)` | uuid row |
| transport | `membershipInfoFromTelegramChat(chat, count)` | `chat.type` + count → `MembershipInfo` |
| transport | `telegramChatMembershipInfo(pg, chat)` | chat-level count из PG + boundary VO |
| storage | `updateConversationMembershipInfoByKeys` | bulk write `member_count` + effective `dialog_arity` |

`transport` tag — аргумент `TELEGRAM_TAG` на call site, не поле patch.

```mermaid
flowchart LR
  subgraph events ["grammY events"]
    MCM["my_chat_member"]
    NCM["new_chat_members"]
    LCM["left_chat_member"]
    MSG["message / commands"]
  end

  subgraph chat_path ["из Chat / Message"]
    PATCH["conversationRowTitlePartialFromChat"]
    KEY["encodeTelegramConversationKey"]
    ENS["ensureConversation"]
    ING["persistIngress → saveMessage"]
  end

  subgraph members ["members.ts"]
    WRT["writeTelegramMemberCount"]
    INIT["initMemberCount"]
    API["getChatMemberCount"]
  end

  MCM --> API --> WRT
  NCM --> WRT
  LCM --> WRT
  MSG --> PATCH --> ENS
  MSG --> KEY --> ENS --> ING
  MSG --> INIT
  INIT -->|"chatCount null"| API
  INIT -->|"topic null, chat set"| WRT
```

### `MembershipInfo`, member_count и member events

| Источник | Действие |
|----------|----------|
| `my_chat_member` (бот в чате) | `getChatMemberCount` → `writeTelegramMemberCount` (chat + все topic rows в PG) |
| `new_chat_members` | `+delta` (все в списке, включая ботов) от chat-level count; **без API** |
| `left_chat_member` | `−1` (включая ботов); **без API** |
| `message` (turn-path) | после `persistIngress`: `initMemberCount` — идемпотентно по PG (см. ниже); **не** на `/ask` |
| ingress (`persistIngress`) | **не трогает** count/arity |
| qualifying / turn | `telegramChatMembershipInfo` → `MembershipInfo.dialogArity` |

**`writeTelegramMemberCount`:** `membershipInfoFromTelegramChat(chat, count)` → `updateConversationMembershipInfoByKeys` на `[chatKey, …topicKeys]` (topic keys — `listExternalKeysByPattern`).

**`initMemberCount`** (только group/supergroup, только generic `message` handler):

| Состояние PG | Действие |
|--------------|----------|
| chat-level `member_count` null | `getChatMemberCount` → `writeTelegramMemberCount` |
| chat-level заполнен, не forum-topic | skip (один read) |
| chat-level заполнен, forum-topic, topic-row null | `writeTelegramMemberCount(chatCount)` — backfill denorm, **без API** |
| оба заполнены | skip |

Явного счётчика «первого вызова» нет — только `null` / not `null` в PG.

**Не делаем:** bootstrap count на **каждое** сообщение; протаскивание `api` через ingress; hub `resolveTelegramConversation` / `TelegramRuntime`. Welcome — [#87](https://github.com/skepsik/utlas-ts/issues/87).

**Qualifying / turn:** `qualifiesForTurn(message, api, membershipInfo.dialogArity)` — effective arity из VO, не сырой `chat.type`.

---

## Термины

| Термин | Смысл |
|--------|--------|
| **Ingress** | Сырой event → `MessageRef` → persist. Quote, forward, reply, `sentAt`, participant — здесь. |
| **Egress** | Ответ наружу: wire (HTML, threading) + опциональный persist. Turn и handlers знают только **`OutboundPort.deliver`**. |
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
  types.ts                OutboundPort, ConversationOutboundItem, Transport, …
  turn-qualification.ts   TurnQualification + TurnQualificationFactory
  factory.ts              createTransport (type guard)
  registry.ts             TransportRegistry
  index.ts

  telegram/
    bot.ts                createTelegramBot → Transport; shared OutboundPort
    handlers.ts           grammY wiring: persist → gate → turn
    chat.ts               telegramChatTitle, membershipInfoFromTelegramChat, telegramChatMembershipInfo
    ingress.ts            tgMessageToRef, persistIngress
    conversation-key.ts   encode/decode external_key; telegramWireTarget (egress)
    members.ts            member events + initMemberCount + writeTelegramMemberCount
    forward.ts            parseQuote, parseForward, parseForwardLabel
    trigger.ts            qualifiesForTurn, shouldRespondInGroup
    egress.ts             createTelegramOutboundPort, wire + persist by policy
    outbound-context.ts   OutboundContext from grammY message (egress вне turn)
    outbound-deliver.ts   deliverEphemeralFromMessage (handlers / settings)
    format.ts             markdownToTelegramHtml
    edits.ts              edited_message → updateMessageText
    settings.ts           /settings → chats table + OutboundPort ephemeral
    texts.ts, constants.ts
    index.ts              createTelegramBot
```

**Вне transport/** (agnostic): `@utlas/core` (`domain/`, `storage/`, `llm/`), `apps/runtime` (`turn/`, `enrichment/`, `clients/`, `orchestrator/`, `main.ts`).

---

## Ports (`transport/types.ts`)

### OutboundPort ([#69](https://github.com/skepsik/utlas-ts/issues/69))

Единый egress наружу: **wire + persist по policy** в одном вызове. Не `BotEgress`, не `TurnEgress`, не domain `Utterance`.

```ts
type ConversationOutboundItem =
  | { kind: "text"; body: string }
  | { kind: "map_pin"; lat: number; lon: number; label: string };

/** history = messages / CHAT HISTORY; ephemeral = wire only */
type OutboundPersistPolicy = "history" | "ephemeral"; // default: history

type OutboundPort = {
  deliver(
    item: ConversationOutboundItem,
    ctx: OutboundContext,
    persist?: OutboundPersistPolicy,
  ): Promise<MessageRef | void>;
};
```

Impl: `createTelegramOutboundPort({ api, pg })` в `telegram/egress.ts`. Turn, tool runners и transport handlers вызывают **`deliver`**; grammY не импортирует из `turn/`.

**Три оси (не смешивать):**

| Ось | Что | Где |
|-----|-----|-----|
| **Conversation item** | Вид для пользователя / CHAT HISTORY | `ConversationOutboundItem`: `text`, `map_pin`, … |
| **Persist policy** | История vs временный вывод в чат | 3-й аргумент `deliver`, **не** поле внутри `kind` |
| **Observability** | `llm_calls`, `generation_failures`, `console.*` | **вне** `OutboundPort` |

`log` — **не** `kind` рядом с `map_pin`. Debug/trace в TG = `deliver(..., "ephemeral")`.

**Матрица (v1):**

| Запись | Egress (чат) | `persist` | Куда |
|--------|--------------|-----------|------|
| Ответ модели (`shouldReply`) | да | `history` | `messages` |
| Map pin | да | `history` | `messages` + `map_pin` payload |
| Debug: `DEBUG_SILENT`, ошибки в debugMode | да | `ephemeral` | операторский trace в TG |
| User-visible LLM error (не debug) | да | `ephemeral` | короткий текст в TG |
| UI вне turn (`/settings`, `/forget`, пустой `/ask`) | да | `ephemeral` | подтверждение / статус |
| LLM invoke audit | нет | — | `llm_calls` (llm-слой) |
| Generation incident (fail turn) | по политике (см. § ниже) | `ephemeral` или нет | `generation_failures` (**всегда**) |
| `console.*` | нет | — | ops |

Turn / tools выбирают `item` + `persist`; port — wire + сохранение. `replyToForAnchor` / `telegramReplyTo` — threading в `OutboundContext`, не в имени порта.

**Reject:** `send`/`push` как имя порта; `log` как `kind`; склейка policy внутри `egress.ts` по `debugMode` для save.

**Позже:** `InboundPort.ingest` ≈ `persistIngress` (имя зафиксировано; порт — не в v1).

### Generation failures ([#76](https://github.com/skepsik/utlas-ts/issues/76))

Единая обработка ошибок generation: **durable audit** + **ephemeral egress** из одного handler'а — не размазывать по catch'ам.

**Impl:** `handleGenerationFailure` в `apps/runtime/src/turn/handle-generation-failure.ts`; вызывается из `runGeneration` и safety net на reject `GenerationTask` (`run-turn.ts`).

```text
любой перехваченный fail generation
  → console.error
  → logGenerationFailure (PG, всегда; не зависит от debugMode)
  → failureEgressText → optional OutboundPort.deliver(..., ephemeral)
```

**Две оси observability (не смешивать):**

| Store | Роль |
|-------|------|
| **`llm_calls`** | Audit **invoke**: latency, provider, `status: ok \| error` на границе `generateReply` |
| **`generation_failures`** | **Incidents** turn: фаза, `error_text`, `http_code`, `trigger_message_id` |

Один LLM error даёт **обе** записи: `llm_calls` (invoke) + `generation_failures` (incident + egress policy).

**Фазы** (`GenerationFailurePhase`): `llm` | `tool` | `egress` | `settings` | `other`.

| Фаза | Откуда |
|------|--------|
| `llm` | `generateReply` / compose / enrichment read в том же `try` |
| `tool` | `runToolLoop` |
| `settings` | `applyConversationSettings` после успешного answer |
| `egress` | `outbound.deliver` ответа модели |
| `other` | reject `GenerationTask` вне `runGeneration` |

**Ephemeral egress** (`failureEgressText`):

| `debugMode` | Фаза | Чат |
|-------------|------|-----|
| on | любая | `formatDebugError(err)` |
| off | `llm` | короткий `LLM_ERROR` |
| off | `tool` / `egress` / `settings` / `other` | тишина |

`sendEphemeralEgress` уважает supersede (`shouldDiscardOnSend`) — как обычный egress.

**Вне handler'а:**

- **Enrichment** — swallow + пустой fragment (`enrichTurn`); отдельная политика, не `generation_failures`
- **Abort** (`AbortError`) — без audit и без egress
- **Debug silent** (`shouldReply: false` + `debugMode`) — `sendEphemeralEgress(DEBUG_SILENT)`, не failure

Schema: [storage-mapping](./storage-mapping.md) § `generation_failures`. Тесты матрицы: `apps/runtime/test/turn-generation-failure.test.ts` ([#80](https://github.com/skepsik/utlas-ts/issues/80)).

### Слой / pipeline / порт

| Уровень | Вход | Выход |
|---------|------|--------|
| **Слой transport** | ingress | egress |
| **Шаг pipeline** (orchestrator YAML) | `ingress` | `deliver` |
| **Метод порта** | `ingest` (later) | **`deliver`** |

`StepRegistry` регистрирует orchestrator-step `"deliver"` (stub [#58](https://github.com/skepsik/utlas-ts/issues/58)); runtime egress — тот же `OutboundPort`.

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
  ├─ my_chat_member  → members.ts → getChatMemberCount → writeTelegramMemberCount
  ├─ new_chat_members / left_chat_member → members.ts → ±delta → writeTelegramMemberCount
  ├─ /settings     → ensureConversation + getConversationRecord → ephemeral
  ├─ /forget       → resetConversationContext → ephemeral
  ├─ /ask          → persistIngress → telegramChatMembershipInfo → TurnRequest.fromAsk → runTurn
  ├─ edited_message → ensureConversation → updateMessageText
  └─ message       → persistIngress → initMemberCount → telegramChatMembershipInfo → qualifiesForTurn → runTurn
```

Все message handlers — `persistIngress({ pg })` без `api`. `api` в members на `my_chat_member` и в `initMemberCount` (когда chat-level count ещё null); в `/settings` — `getChatMember` для admin check.

**Persist всегда до gate** — сообщения без qualifying тоже сохраняются.

**Команды с `/`** в generic handler пропускаются (`message.text?.startsWith("/")`).

### Ingress (`ingress.ts` + `forward.ts` + `chat.ts`)

- `encodeTelegramConversationKey` + `conversationRowTitlePartialFromChat(chat)` → `ensureConversation` → uuid
- `tgMessageToRef` → `saveMessage` — **не трогает** `member_count` / `dialog_arity`

### Egress вне turn (`outbound-deliver.ts` + `outbound-context.ts`)

- `deliverEphemeralFromMessage(outbound, pg, message, body)`
- `outboundContextFromTelegramMessage(pg, message)` — ensure + `getConversationRecord` + `telegramChatMembershipInfo`

### Qualifying (`trigger.ts`)

`dialogArity` — аргумент `qualifiesForTurn` из `MembershipInfo.dialogArity` (**не** сырой `chat.type`).

| `dialogArity` / условие | `via` |
|-------------------------|-------|
| `private` | `private` (все сообщения в 1:1 или duo) |
| `group` + reply на сообщение бота | `reply_to_bot` |
| `group` + `@mention` бота в entities | `mention` |
| `group`, иначе | reject `not_for_bot` |

`/ask` — **обходит** qualifying (явный вызов).

### Egress (`egress.ts` + `format.ts` + `conversation-key.ts`)

- `telegramWireTarget(pg, conversationId)` — uuid → `chat_id` + `message_thread_id?`
- `createTelegramOutboundPort.deliver` — единая точка wire + persist
- `markdownToTelegramHtml` → `parse_mode: "HTML"`; fallback plain text при ошибке API
- длинные ответы — chunk по 4096
- `reply_parameters.message_id` когда `replyToMessageId` в `OutboundContext`
- `persist: "history"` — persist исходящего с `sender.isBot`, `anchorRef` = trigger
- `persist: "ephemeral"` — только wire, **без** row в `messages`
- **Map pin** ([#65](https://github.com/skepsik/utlas-ts/issues/65)): `kind: "map_pin"` → `sendLocation` + `MessagePayload` в PG — [tools/composite](./tools/composite.md) § Память; runner вызывает `OutboundPort.deliver`, не grammY из `turn/`
- **Вне turn** ([#75](https://github.com/skepsik/utlas-ts/issues/75)): `deliverEphemeralFromMessage` в handlers/settings — тот же port, `OutboundContext` из command message

**Threading policy** (`telegramReplyTo` / `replyToForAnchor` в turn):

- private без reply на trigger → без `reply_parameters`
- иначе → reply на `anchor.id`

### Message lifecycle: edit / delete

Transport отвечает только за **синхронизацию PG с тем, что мессенджer сообщил**. Turn/LLM — отдельно.

| Событие | Telegram v0 | Политика |
|---------|-------------|----------|
| **Edit** (`edited_message`) | ✅ приходит | `edits.ts` → `updateMessageText`: обновить **только** `messages.text`. Quote / forward / reply / `sentAt` **не** пересчитывать. **Без** `runTurn`. |
| **Edit → пусто** (текст и caption сняты) | ✅ как edit | Считать **очисткой контента**, не delete row: persist `text = ""`. *(Сейчас skip — stale; small fix в transport.)* |
| **Delete** (сообщение исчезло без edit) | ❌ Bot API не шлёт update в private/group | Row в PG **не удалять** — last-known snapshot. Reply-chain и `llm_calls` ссылаются на `message_id`. |
| **Delete** (другие transport / Business API) | later | Опционально `deleted_at` + tombstone; row по-прежнему не DELETE. |

**Не делаем на transport:**

- hard `DELETE` из `messages`
- regen ответа бота при edit — **turn** (later)

**Принцип:** PG — append-only archive по `(conversation_id uuid, message_id)`; transport правит только поля, которые реально пришли в update.

---

## Transport tag на boundary

Transport tag — conversation scope, не utterance. Ingress: `TELEGRAM_TAG` в `saveMessage` и `TurnRequest.fromMessage({ transport })`; prompt — `ctx.transport`. **Не поле `MessageRef`.** [#33](https://github.com/skepsik/utlas-ts/issues/33) ✅. Hub: [domain](./domain.md) § Transport tag.

## Стык с turn

```ts
// membershipInfo — telegramChatMembershipInfo после persistIngress (+ initMemberCount на message path)
TurnRequest.fromMessage({ anchor, membershipInfo, outbound, services, supersedeMaxGapMs, transport })
TurnRequest.fromAsk({ ... , text, membershipInfo, outbound, transport })
// request.arity === membershipInfo.dialogArity
```

Turn pipeline **не** импортирует grammY. Egress только через **`OutboundPort`** на request.

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

- `membershipInfoFromTelegramChat` (wire + duo → effective private)
- `parseQuote`, `parseForward`, `parseForwardLabel`
- `tgMessageToRef` (quote-only, forward)
- `qualifiesForTurn` / `shouldRespondInGroup` (private arity, mention, reply, reject)

`test/conversation-key.test.ts` — encode/decode, General topic.  
`test/dialog-arity-persist.test.ts` — `updateConversationMembershipInfoByKeys` на topic row.  
`test/member-handlers.test.ts` — join/leave, `initMemberCount`, bulk write.  
`test/ingress-conversation.test.ts` — forum topic uuid / general key.

---

## v0 checklist

- [x] `transport/telegram/`; grammY только там
- [x] Ingress: text, quote, forward, reply, links, persist
- [x] Qualifying: private / @mention / reply_to_bot
- [x] `/ask`, `/forget`, `/settings`
- [x] Egress: HTML, chunk, reply threading, `OutboundPort.deliver` + `history` / `ephemeral`
- [x] `edited_message` → update text in PG (см. § Message lifecycle)
- [x] Delete policy: no row DELETE; Telegram delete N/A v0
- [x] `OutboundPort`; turn без SDK import ([#69](https://github.com/skepsik/utlas-ts/issues/69))
- [x] Egress вне turn через тот же port ([#75](https://github.com/skepsik/utlas-ts/issues/75))
- [x] `TurnQualification` boundary type
- [ ] Ingress transform (STT / enrichment pre-capture) — later
- [x] Media / caption-only без текста
- [x] `telegramReplyTo` vs `replyToForAnchor` — dedupe ([#29](https://github.com/skepsik/utlas-ts/issues/29))
- [x] Conversation uuid + `external_key`; forum topics ([#81](https://github.com/skepsik/utlas-ts/issues/81) #82–#84)
- [x] Member events + `initMemberCount` + bulk denorm `member_count` / `dialog_arity` ([#81](https://github.com/skepsik/utlas-ts/issues/81) #85)
- [x] `MembershipInfo` + qualifying из effective arity ([#81](https://github.com/skepsik/utlas-ts/issues/81) #86)

---

## Open

- [ ] **`bot_off` в TurnQualification** — перенести check из `runTurn` в trigger или убрать из type

## Later

- [ ] **Second transport** — шаблон подпапки + registry factory
- [ ] **Ingress enrichment** — hook до `persistIngress`
- [ ] **Multi-bot** — qualifying на self binding per [tenancy](./tenancy.md)
- [ ] **Empty edit → `text=""`** — transport (`edits.ts`)
- [ ] **LLM regen on edit** — turn, не transport
