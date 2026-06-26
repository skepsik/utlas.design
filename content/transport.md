# Transport

**Transport layer** — доставка human↔assistant через messengers: ingress, qualifying, egress. Один мессенджer = подпапка `transport/<name>/`; SDK и event wiring **только** там.

Домен ([domain](./domain.md)) agnostic: `MessageRef`, turn. Transport нормализует сырой event → `MessageRef` и обратно.

**Сейчас:** Telegram v0 — [checklist](#v0-checklist) ниже.

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
    handlers.ts           grammY wiring: commands + message handler
    ingress.ts            tgMessageToRef, persistIngress
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
  ├─ /settings     → settings.ts → OutboundPort ephemeral (без turn)
  ├─ /forget       → resetChatContext → OutboundPort ephemeral
  ├─ /ask          → persistIngress → TurnRequest.fromAsk → runTurn
  │                  (пустой текст → ephemeral, без turn)
  ├─ edited_message → updateMessageText (edits.ts)
  └─ message       → persistIngress
                       → qualifiesForTurn?
                       → TurnRequest.fromMessage → runTurn
```

**Persist всегда до gate** — сообщения без qualifying тоже сохраняются.

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

**Принцип:** PG — append-only archive по `(transport, chat_id, message_id)`; transport правит только поля, которые реально пришли в update.

---

## Transport tag на boundary

Transport tag — conversation scope, не utterance. Ingress: `TELEGRAM_TAG` в `saveMessage` и `TurnRequest.fromMessage({ transport })`; prompt — `ctx.transport`. **Не поле `MessageRef`.** [#33](https://github.com/skepsik/utlas-ts/issues/33) ✅. Hub: [domain](./domain.md) § Transport tag.

## Стык с turn

```ts
TurnRequest.fromMessage({ anchor, arity, outbound, services, supersedeMaxGapMs, transport })
TurnRequest.fromAsk({ ... , text, outbound, transport })  // textOverride для USER MESSAGE
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

- `parseQuote`, `parseForward`, `parseForwardLabel`
- `tgMessageToRef` (quote-only, forward)
- `qualifiesForTurn` / `shouldRespondInGroup` (private, mention, reply, reject)

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

---

## Open

- [ ] **`bot_off` в TurnQualification** — перенести check из `runTurn` в trigger или убрать из type

## Later

- [ ] **Second transport** — шаблон подпапки + registry factory
- [ ] **Ingress enrichment** — hook до `persistIngress`
- [ ] **Multi-bot** — qualifying на self binding per [tenancy](./tenancy.md)
- [ ] **Empty edit → `text=""`** — transport (`edits.ts`)
- [ ] **LLM regen on edit** — turn, не transport
