# Conversation settings

**`conversationSettings`** — declare-patch в [answer envelope](./index.md): формальные per-conversation поля с **server-side validate** и persist в PG. Не scratchpad: [scratchpad](./scratchpad.md) § vs `conversationSettings`.

Новый declare-ключ — чеклист [attention/conversation-settings-declare](../attention/conversation-settings-declare.md).

Envelope hub: [index](./index.md).

---

## Типы

**Storage / read** (`@utlas/core/storage`):

```ts
type ConversationRecord = {
  conversationId: string;
  botEnabled: boolean;
  debugMode: boolean;
  contextLimitOverride: number | null;
  timezone: string | null;   // IANA; [#48](https://github.com/skepsik/utlas-ts/issues/48)
  title: string | null;
  memberCount: number | null;   // this row only; turn/qualify — chat-level via MembershipInfo ([#81](https://github.com/skepsik/utlas-ts/issues/81))
  transport: TransportTag;
};
```

`dialogArity` **не** в `ConversationRecord` — effective arity на turn boundary: `TurnRequest.membershipInfo.dialogArity` ([domain](../domain.md) § MembershipInfo).

`botEnabled`, `debugMode`, `contextLimitOverride` — transport [`/settings`](../transport.md); в answer **не** входят.

**Wire (answer):**

```ts
type AnswerConversationSettings = Partial<
  Pick<ConversationRecord, 'timezone'>
>;
```

JSON-ключ в `LlmAnswer` — `conversationSettings`. Пока одно поле и политика omit / set / clear совпадает с storage — достаточно `Pick`. Иначе — per-field declare (§ attention).

| Ключ | omit | set | `null` (clear) |
|------|------|-----|----------------|
| `timezone` | no-op | valid IANA → write | clear column |

---

## Wire

Top-level optional в `LlmAnswer` (declare-фаза; **не** `toolCalls`).

| Правило | Поведение |
|--------|-----------|
| `conversationSettings` **omit** | storage не меняем |
| ключ **omit** | поле не трогаем |
| **string** + valid | write |
| **`null`** | clear (для `timezone`) |
| **invalid** | log + ignore; turn не ломаем |

---

## Storage

v0: колонки на `conversations` (uuid PK; wire — `external_key`). Multi-bot — [tenancy](../tenancy.md) later.

| Поле | PG (v0) | Writer |
|------|---------|--------|
| `botEnabled`, `debugMode`, `contextLimitOverride` | `conversations.*` | transport `/settings` |
| `dialog_arity`, `member_count` | `conversations.*` | transport `members.ts` (`MembershipInfo` → bulk denorm); не declare из answer |
| `timezone` | `conversations.timezone` | declare, UI (later), transport bootstrap (later) |
| `title` | `conversations.title` | `conversationRowTitlePartialFromChat` on ingress / commands |

---

## Apply (declare)

Порядок — [index](./index.md) § Turn apply: patches **до** deliver; в т.ч. при `shouldReply: false`.

**Default (v0):** valid → write; omit → no-op; `null` → clear где разрешено для ключа.

Transport bootstrap (`if null`) и per-source overwrite flags — later; не смешивать с model apply.

---

## Read-path (промпт)

До compose; patch того же turn — со **следующего** turn.

```text
effectiveTz = conversation.timezone ?? tenant.timezone ?? null   # tenant — [#25](https://github.com/skepsik/utlas-ts/issues/25) later
```

**Приоритет:** настройки чата сильнее tenant. Запись в один чат не трогает tenant и другие строки `conversations`.

---

## Timezone

### Канон

- **IANA**; validate `Intl.DateTimeFormat`.
- `sentAt` / PG — UTC instant; в промпте — `effectiveTz` или UTC.
- **Meta:** `Timestamps: Europe/Moscow (local).` / `Timestamps: UTC (timezone unknown).`
- **На сообщениях:** local или UTC.
- **private и group** — одна логика.

### Writers

| Источник | Когда |
|----------|--------|
| Model `conversationSettings.timezone` | valid → write; `null` → clear |
| UI (TMA, админка) | later |
| Transport ingress | bootstrap **if null** (later; TG не даёт TZ) |
| Tenant | fallback в read-path ([#25](https://github.com/skepsik/utlas-ts/issues/25)) |

Модель и UI — explicit intent. Transport bootstrap — только пока колонка пуста.

### Prompt (model declare)

PG `conversation_settings.timezone` ([turn-prompt](../turn-prompt.md)).

**Канон:** patch **только** если пользователь **явно** назвал локацию и есть **уверенность** в одном valid IANA. **Нет уверенности → не обновлять** (omit declare, спросить в `text`). Не угадывать, не маппить расплывчое; meta и лента — read, не основание для patch. `null` — явный clear. [#59](https://github.com/skepsik/utlas-ts/issues/59).

---

## Scratchpad vs settings

| | `conversationSettings` | `scratchpad` |
|---|------------------------|--------------|
| Validate | server (IANA, …) | schema + size |
| Persist | `conversations` | declarative snapshots |
| Пример | timezone | userPreferences |

---

## В коде (timezone)

- Read-path: колонка, `formatSentAt`, meta в user ([#48](https://github.com/skepsik/utlas-ts/issues/48)).
- Declare apply: `conversationSettings.timezone` в answer → `applyConversationSettings` в `runTurn` до deliver ([#58](https://github.com/skepsik/utlas-ts/issues/58)).

## Later

- [ ] Новые ключи — секция здесь + [attention](../attention/conversation-settings-declare.md)
- [ ] `timezoneOverwrite` policy per source
- [ ] Tenant `timezone` — [#25](https://github.com/skepsik/utlas-ts/issues/25)

## Rejected

- **`Partial<ConversationSettings>` на answer** — тянет transport-only поля (`botEnabled`, `debugMode`, …); declare = whitelist (`Pick` / per-field). Чеклист при добавлении ключа — [attention](../attention/conversation-settings-declare.md).
