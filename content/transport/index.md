# Transport

**Transport layer** — доставка human↔assistant через messengers: ingress, qualifying, egress. Один мессенджer = подпапка `transport/<name>/`; SDK и подписка на события **только** там.

Домен ([domain](../domain/)) agnostic: `MessageRef`, turn. Transport переводит сырой event мессенджера в `MessageRef` и обратно — turn и storage не знают wire.

**Сейчас:** единственная реализация — [Telegram v0](./telegram.md). Симметричные порты ingress/egress ([#110](https://github.com/skepsik/utlas-ts/issues/110), [#69](https://github.com/skepsik/utlas-ts/issues/69)); identity чата — uuid + `external_key` ([#81](https://github.com/skepsik/utlas-ts/issues/81)). Egress: split `telegram/outbound/`, `OutboundPort.wire()` + `deliver()` ([#126](https://github.com/skepsik/utlas-ts/issues/126)); turn v0 по-прежнему только `deliver` (batch `wire` → PG — [#117](https://github.com/skepsik/utlas-ts/issues/117)).

**Peer:** [bot-peer](./peer.md) — протокол bot↔bot, паритет Bot API Getting updates (в коде ещё нет).

---

## Термины

| Термин | Смысл |
|--------|--------|
| **Ingress** | Сырой event → нормализация → persist `MessageRef`. Quote, forward, reply, `sentAt`, participant — на этой границе. |
| **Egress** | Исходящее в чат: wire-формат + опциональная запись в историю. Turn и команды ходят только через **`OutboundPort`**. |
| **Qualifying** | «Это обращение к **нашему** боту?» — решается в transport, **до** `runTurn`. |
| **Transport** | Ingress + qualifying + egress + подписка на события одного мессенджера. |

---

## Зачем отдельный слой

Каждый мессенджer живёт в своей подпапке; снаружи — factory и `TransportRegistry`. Domain, turn и storage не импортируют SDK мессенджера. Добавление второго transport — новая подпапка и регистрация, без правок ядра.

---

## Ports

Контракты в `transport/types/` (barrel `index.ts`). Wire-специфика — в подпапке мессенджера ([Telegram](./telegram.md)).

### InboundPort ([#110](https://github.com/skepsik/utlas-ts/issues/110))

Единый ingress **снаружи**: один вызов принимает нормализованное сообщение и пишет его в PG. Симметрия с `OutboundPort.deliver`. Listeners не вызывают storage напрямую.

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

v0: только `kind: 'user_message'`. Расширения (choice, callback) — отдельные work.

### InboundContext ([#110](https://github.com/skepsik/utlas-ts/issues/110))

Контекст одного `ingest`: **в какой разговор** писать. Полный `MessageRef` лежит в `item`; context — только uuid строки `conversations`.

```ts
type InboundContext = { conversationId: string };
```

| Поле | Смысл |
|------|--------|
| `conversationId` | uuid row в PG |

Если uuid в `item.ref` не совпадает с context — port возвращает `null` (защита от рассинхрона на границе).

| Поле item | Смысл |
|-----------|--------|
| `ref` | готовый `MessageRef` для persist |
| `rawText` | тело для колонки в PG |
| `quotedText`, `quotePosition` | цитата, если была на wire |

На Telegram envelope собирается до вызова port: найти/создать row чата, разобрать wire-сообщение в `MessageRef`, затем `ingest`. Подробнее — [Telegram § Ingress](./telegram.md#ingress).

```text
prepareTelegramUserMessageInbound → InboundEnvelope
createTelegramInboundPort({ pg }).ingest(envelope)
```

### OutboundPort ([#69](https://github.com/skepsik/utlas-ts/issues/69))

Единый egress **наружу**: отправка в чат и (по политике) запись исходящего в историю — один вызов. Не отдельные «BotEgress» / domain `Utterance`.

```ts
type OutboundItem =
  | { form: "text"; body: string }
  | { form: "points"; lat: number; lon: number; label: string };

type OutboundPersistPolicy = "history" | "ephemeral"; // default: history

type WireReceipt =
  | {
      form: "text";
      messageId: string;
      sentAt: Date;
      anchorRef: string | null;
      conversationId: string;
      sender: ParticipantRef;
      userId: string;
      textBody: string;
    }
  | {
      form: "points";
      messageId: string;
      sentAt: Date;
      anchorRef: string | null;
      conversationId: string;
      sender: ParticipantRef;
      userId: string;
      textBody: "";
      payload: PointsPayload; // domain payload.type === "points"
    };

type OutboundPort = {
  /** Messenger send; batch PG — turn flush (#117), not a third persist policy. */
  wire(
    item: OutboundItem,
    ctx: OutboundContext,
  ): Promise<WireReceipt>;
  deliver(
    item: OutboundItem,
    ctx: OutboundContext,
    persist?: OutboundPersistPolicy,
  ): Promise<MessageRef | void>;
};
```

**`form`** — transport-форма egress-контента (ветка union item/receipt). Не `MessagePayload.type`, не wire-encoding (`parse_mode` / markdown→HTML).

Wire (HTML, chunking, `sendLocation`) — в [Telegram § Egress](./telegram.md#egress).

### OutboundContext ([#89](https://github.com/skepsik/utlas-ts/issues/89))

Контекст одного `deliver`: **куда** слать и **как** привязать persist. Сообщение, открывшее turn или команду (**trigger**), и wire-reply — **разные** поля.

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
| `conversation` | снимок для persist и prompt boundary; тип `OutboundConversation` — `transport/types/outbound-port.ts`, builder `outbound-conversation.ts` ([#97](https://github.com/skepsik/utlas-ts/issues/97)), не storage |
| `triggerMessageId` | id сообщения-повода; anchor при записи исходящего |
| `replyToMessageId` | только wire-reply; **по умолчанию не задаётся** |

Turn собирает context в `turn/outbound-context.ts` (`outboundContextForTurn`). Классический ответ модели — preset «reply на trigger»; правило *когда* reply уместен — domain `replyTargetForTrigger` ([domain](../domain/) § Outbound reply threading). Команды и ephemeral вне turn — `outboundContextFromTelegramMessage` (**без** `replyToMessageId`).

**Три оси (не смешивать):**

| Ось | Смысл |
|-----|--------|
| **Item (`form`)** | Что видит пользователь (`text`, `points`, …) |
| **Persist policy** | Пишем в `messages` или только в чат (`history` / `ephemeral`) |
| **Batch history** | Turn egress: `wire()` → `WireReceipt`; PG batch на `turn:finished` (#109, #117) |
| **Observability** | `llm_calls`, `generation_failures`, логи — **вне** port |

**Куда что попадает (v0):**

| Событие | В чат | В `messages` | Ещё |
|---------|-------|--------------|-----|
| Ответ модели (`shouldReply`) | да | да | — |
| Map pin | да | да | `MessagePayload` `points` |
| Debug / ошибка LLM | по политике | нет (`ephemeral`) | — |
| `/settings`, `/forget`, пустой `/ask` | да | нет | — |
| Invoke LLM | нет | нет | `llm_calls` |
| Сбой generation | по политике | нет | `generation_failures` всегда |

**Reject:** имена `send`/`push`; `log` как вид item; смешивание debug-политики внутри port impl.

### Generation failures ([#76](https://github.com/skepsik/utlas-ts/issues/76))

Любой сбой generation в turn проходит через один handler: лог в консоль, **всегда** запись в `generation_failures`, опционально короткий текст в чат (`ephemeral`). Invoke-аудит — отдельно в `llm_calls`; это не substitute.

Фазы incident: `llm`, `tool`, `egress`, `settings`, `other`. В debug-режиме чата — полный trace ошибки; иначе пользователю виден только короткий текст при сбое LLM, остальные фазы — тишина.

Schema: [storage-mapping](../storage-mapping.md) § `generation_failures`.

### Слой vs pipeline vs port

| Уровень | Вход | Выход |
|---------|------|--------|
| Слой transport | ingress | egress |
| Шаг orchestrator (YAML) | `ingress` | `deliver` |
| Метод port | `ingest` | `deliver` |

Шаг `"deliver"` в orchestrator — stub ([#58](https://github.com/skepsik/utlas-ts/issues/58)); runtime уже ходит в тот же `OutboundPort`.

### Transport (lifecycle)

```ts
Transport { type: TransportTag; start(): Promise<void>; stop(): Promise<void> }
```

Регистрация в `TransportRegistry` из composition root.

### TurnQualification

Результат qualifying на границе transport — **не** domain entity:

```ts
| { qualifies: true; via: "private" | "mention" | "reply_to_bot" }
| { qualifies: false; reason: "not_for_bot" | "bot_off" | "command" }
```

Правила для Telegram — [telegram § Qualifying](./telegram.md#qualifying). Вариант `bot_off` в type зарезервирован; фактически «бот выключен» проверяется в `runTurn`, не в trigger.

---

## Transport tag на boundary

Тег transport — scope **разговора**, не utterance. Persist ingress и `TurnRequest` несут tag; в prompt — `ctx.transport`. **Не поле `MessageRef`.** [#33](https://github.com/skepsik/utlas-ts/issues/33). Hub: [domain](../domain/) § Transport tag.

Канон значений — `TransportTag` в domain (`TransportTag.telegram`, …). Composition root: `createConversationWireStore(pg, TransportTag.telegram)`; handlers — `store.transport`, без дублирования литерала на call sites ([#98](https://github.com/skepsik/utlas-ts/issues/98)).

### Storage boundary ([#94](https://github.com/skepsik/utlas-ts/issues/94))

Transport **не** вызывает UPSERT `conversations` напрямую: `ConversationWireStore` + `TelegramMembershipResolver` в handler deps. `saveMessage` / `updateMessageText` пока на `pg` + `store.transport`. Детали — [storage-mapping](../storage-mapping.md).

---

## Стык с turn

Transport после ingress передаёт в `runTurn` anchor (`MessageRef`), `membershipInfo` (effective arity чата), порты ingress/egress и transport tag. `request.arity` совпадает с `membershipInfo.dialogArity`. Turn **не** импортирует SDK мессенджера.

`/ask` с текстом — тот же ingress, но **без** qualifying; отдельный pipeline не нужен.

---

## Enrichment

**v0:** обогащение контекста — hook внутри `runTurn`, не до persist. Цепочка «enrichment → capture» на ingress — **Later**.

---

## Transport ≠ connectors

| | Transport | Clients |
|---|-----------|------------|
| Назначение | Messengers: in/out | Внешние API (Obsidian, Jira, …) |
| Registry | `TransportRegistry` | `ClientRegistry` |
| Domain | `MessageRef` | bindings, orchestrator steps |

Deploy и infra — не connector.

---

## Открытые вопросы

| Тема | Суть |
|------|------|
| `bot_off` в TurnQualification | Перенести проверку «бот выключен» в trigger или убрать вариант из type |

---

## Later

| Тема | Суть |
|------|------|
| Ingress transform | STT / enrichment до `ingest` |
| Second transport | Шаблон подпапки + registry |
| Ingress enrichment hook | Цепочка до capture, не в turn |
| Multi-bot qualifying | Self binding per [tenancy](../tenancy.md) |
| Peer protocol | Bot↔bot updates мимо Bot API — [peer](./peer.md) |
