# Transport

**Transport layer** — доставка human↔assistant через messengers: ingress, qualifying, egress. Один мессенджer = подпапка `transport/<name>/`; SDK и event wiring **только** там.

Домен ([domain](../domain.md)) agnostic: `MessageRef`, turn. Transport нормализует сырой event → `MessageRef` и обратно.

**Сейчас:** единственная реализация — [Telegram v0](./telegram.md): `InboundPort` / `OutboundPort` ([#110](https://github.com/skepsik/utlas-ts/issues/110), [#69](https://github.com/skepsik/utlas-ts/issues/69)), conversation uuid + `external_key` ([#81](https://github.com/skepsik/utlas-ts/issues/81)).

---

## Термины

| Термин | Смысл |
|--------|--------|
| **Ingress** | Сырой event → `MessageRef` → persist. Quote, forward, reply, `sentAt`, participant — здесь. |
| **Egress** | Ответ наружу: wire + опциональный persist. Turn и handlers знают только **`OutboundPort.deliver`**. |
| **Qualifying** | «Это обращение к **нашему** binding?» — transport-specific, **до** `runTurn`. |
| **Transport** | Ingress + qualifying + egress + wiring для одного мессенджера. |

Ingress = трафик в систему, egress = из системы.

---

## Зачем `transport/`, а не SDK в корне

- Один мессенджer = одна подпапка; снаружи — factory + `TransportRegistry`.
- Новый transport — новая папка + регистрация; domain/turn/storage не трогаем.
- Правило: **messenger SDK только под `transport/<name>/`** (grammY — в `transport/telegram/`).

---

## Ports (`transport/types.ts`)

### InboundPort ([#110](https://github.com/skepsik/utlas-ts/issues/110))

Единый ingress снаружи: нормализованный item → persist `MessageRef`. Симметрия `OutboundPort.deliver`. Listeners вызывают **`inbound.ingest`**, не `saveMessage` напрямую.

```ts
type ConversationInboundItem = {
  kind: 'user_message';
  quotedText: string | null;
  quotePosition: number | null;
  rawText: string;
  ref: MessageRef;
};

type InboundEnvelope = { item: ConversationInboundItem; ctx: InboundContext };

type InboundPort = {
  ingest(envelope: InboundEnvelope): Promise<MessageRef | null>;
};
```

Wire-persist — в подпапке мессенджера ([Telegram](./telegram.md) § Ingress).

### InboundContext ([#110](https://github.com/skepsik/utlas-ts/issues/110))

DTO одного `ingest`: **куда** persist. Нормализованный `MessageRef` — в `item`; ctx — scope conversation row.

```ts
type InboundContext = { conversationId: string };
```

| Поле | Смысл |
|------|--------|
| `conversationId` | uuid row в PG |

Port отклоняет envelope, если `item.ref.conversationId !== ctx.conversationId` → `null` (guard на call site).

**`ConversationInboundItem` (v0):**

| Поле | Смысл |
|------|--------|
| `kind` | v0: только `user_message` |
| `ref` | `MessageRef` для `saveMessage` |
| `rawText` | тело для PG |
| `quotedText`, `quotePosition` | quote metadata (transport-normalized) |

**Сборщики:**

| Путь | Функция |
|------|---------|
| Telegram generic `message`, `/ask` (text) | `prepareTelegramUserMessageInbound` → `InboundEnvelope` |

Impl: `createTelegramInboundPort({ pg })` — wire-agnostic `saveMessage`.

### OutboundPort ([#69](https://github.com/skepsik/utlas-ts/issues/69))

Единый egress наружу: **wire + persist по policy** в одном вызове. Не `BotEgress`, не `TurnEgress`, не domain `Utterance`.

```ts
type ConversationOutboundItem =
  | { kind: "text"; body: string }
  | { kind: "map_pin"; lat: number; lon: number; label: string };

type OutboundPersistPolicy = "history" | "ephemeral"; // default: history

type OutboundPort = {
  deliver(
    item: ConversationOutboundItem,
    ctx: OutboundContext,
    persist?: OutboundPersistPolicy,
  ): Promise<MessageRef | void>;
};
```

Wire-impl — в подпапке мессенджера ([Telegram](./telegram.md) § Egress).

### OutboundContext ([#89](https://github.com/skepsik/utlas-ts/issues/89))

DTO одного `deliver`: куда слать и как persist. **Trigger** (сообщение, открывшее turn / command) и **wire reply** — разные поля.

```ts
type OutboundContext = {
  conversationId: string
  conversation: OutboundConversation
  triggerMessageId?: string   // semantic: audit, persist anchorRef
  replyToMessageId?: string   // wire only; undefined → без reply_parameters
}
```

| Поле | Смысл |
|------|--------|
| `conversationId` | uuid row |
| `conversation` | snapshot для persist / prompt boundary (`OutboundConversation`) |
| `triggerMessageId` | id trigger-сообщения; persist `anchorRef` / audit |
| `replyToMessageId` | только wire; **по умолчанию не задаётся** |

**Сборщики (turn):** `turn/outbound-context.ts` → `outboundContextForTurn`; preset **`replyToTrigger`** для classic answer — domain `replyTargetForTrigger` ([domain](../domain.md) § Outbound reply threading).

**Три оси (не смешивать):**

| Ось | Что | Где |
|-----|-----|-----|
| **Conversation item** | Вид для пользователя / CHAT HISTORY | `ConversationOutboundItem` |
| **Persist policy** | История vs временный вывод | 3-й аргумент `deliver` |
| **Observability** | `llm_calls`, `generation_failures`, `console.*` | **вне** `OutboundPort` |

**Матрица egress (v0):**

| Запись | Egress (чат) | `persist` | Куда |
|--------|--------------|-----------|------|
| Ответ модели (`shouldReply`) | да | `history` | `messages` |
| Map pin | да | `history` | `messages` + payload |
| Debug / LLM error (политика) | да | `ephemeral` | операторский trace |
| UI вне turn (`/settings`, …) | да | `ephemeral` | подтверждение |
| LLM invoke audit | нет | — | `llm_calls` |
| Generation incident | по политике | `ephemeral` или нет | `generation_failures` (**всегда**) |

**Reject:** `send`/`push` как имя порта; `log` как `kind`; склейка policy внутри port impl по `debugMode`.

### Generation failures ([#76](https://github.com/skepsik/utlas-ts/issues/76))

Единая обработка ошибок generation: **durable audit** + **ephemeral egress** из `handleGenerationFailure` (`turn/handle-generation-failure.ts`).

```text
fail generation → console.error → logGenerationFailure (PG, всегда)
  → failureEgressText → optional OutboundPort.deliver(..., ephemeral)
```

| Store | Роль |
|-------|------|
| **`llm_calls`** | invoke audit |
| **`generation_failures`** | turn incident: фаза, `error_text`, `trigger_message_id` |

Фазы: `llm` | `tool` | `egress` | `settings` | `other`. Ephemeral egress: `debugMode` on → полный trace; off → короткий текст только для `llm`, иначе тишина.

Schema: [storage-mapping](../storage-mapping.md) § `generation_failures`.

### Слой / pipeline / порт

| Уровень | Вход | Выход |
|---------|------|--------|
| **Слой transport** | ingress | egress |
| **Шаг pipeline** (orchestrator YAML) | `ingress` | `deliver` |
| **Метод порта** | **`ingest`** | **`deliver`** |

`StepRegistry` — orchestrator-step `"deliver"` (stub [#58](https://github.com/skepsik/utlas-ts/issues/58)).

### Transport

```ts
Transport { type: TransportTag; start(): Promise<void>; stop(): Promise<void> }
```

Composition root: factory в registry (`main.ts` → `TransportRegistry.register`).

### TurnQualification (`transport/turn-qualification.ts`)

Boundary type для qualifying — **не** domain entity:

```ts
| { qualifies: true; via: "private" | "mention" | "reply_to_bot" }
| { qualifies: false; reason: "not_for_bot" | "bot_off" | "command" }
```

Реализация для Telegram — [telegram](./telegram.md) § Qualifying. `bot_off` в type зарезервирован; **`bot_enabled` проверяется в `runTurn`**.

---

## Transport tag на boundary

Transport tag — conversation scope, не utterance. Persist ingress и `TurnRequest` несут tag; prompt — `ctx.transport`. **Не поле `MessageRef`.** [#33](https://github.com/skepsik/utlas-ts/issues/33). Hub: [domain](../domain.md) § Transport tag.

---

## Стык с turn

```ts
TurnRequest.fromMessage({ anchor, membershipInfo, outbound, services, supersedeMaxGapMs, transport })
TurnRequest.fromAsk({ anchor, text, membershipInfo, outbound, services, supersedeMaxGapMs, transport })
// request.arity === membershipInfo.dialogArity
```

`membershipInfo` — с transport boundary **после** ingress (см. [Telegram](./telegram.md)). Turn **не** импортирует messenger SDK. Egress только через **`OutboundPort`** на request.

---

## Enrichment

**v0:** `runEnrichment` в `runTurn`, не ingress transform. Ingress transform chain — **Later**.

---

## Transport ≠ connectors

| | Transport | Clients |
|---|-----------|------------|
| Назначение | Messengers: ingress / egress | Внешние API (Obsidian, Jira, …) |
| Registry | `TransportRegistry` | `ClientRegistry` |
| Domain | `MessageRef` in/out | bindings, orchestrator steps |

**Git deploy** — `infra/`, не connector.

---

## Открытые вопросы

| Тема | Суть |
|------|------|
| `bot_off` в TurnQualification | Перенести check из `runTurn` в trigger или убрать из union |
| ConversationWireStore ([#99](https://github.com/skepsik/utlas-ts/issues/99)) | Симметрия ensure ingress/egress; interim — [Telegram](./telegram.md) |

---

## Later

| Тема | Суть |
|------|------|
| Ingress transform | STT / enrichment до `inbound.ingest` |
| Second transport | Шаблон подпапки + `TransportRegistry` |
| Ingress enrichment hook | Цепочка до capture, не в turn |
| Multi-bot qualifying | Self binding per [tenancy](../tenancy.md) |
