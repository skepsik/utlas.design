# Conversation settings declare

> **Attention** — чеклист при добавлении ключа в `conversationSettings` (answer envelope), не канон полей.

Канон полей и timezone — [conversation-settings](../envelope/conversation-settings.md).

---

## Контекст

Два типа, не один:

| Тип | Роль |
|-----|------|
| **`ConversationRecord`** | storage / read: per-row PG + defaults (`getConversationRecord`) |
| **`AnswerConversationSettings`** | wire declare: подмножество полей, которые модель может прислать в `LlmAnswer.conversationSettings` |

Transport-only поля (`botEnabled`, `debugMode`, …) — **не** в answer. Envelope hub — [envelope/index](../envelope/index.md).

---

## Правило

**При добавлении каждого нового declare-ключа** — явно пересмотреть:

1. **Storage** — колонка / поле в `ConversationRecord`; миграция; validate на write.
2. **Declare-политика** для этого ключа:

   | Операция | Нужно решить |
   |----------|----------------|
   | omit | всегда = no-op |
   | set | тип значения на wire (= storage value type?) |
   | clear (`null`) | разрешён модели или только UI / transport? |

3. **Тип answer** — привязка к `ConversationSettings`, но политика clear может **отличаться** от storage `| null`.
4. **Apply** в `runTurn` (declare до deliver); **read-path** (промпт) — нужен ли в том же issue.
5. **Prompt policy** — отдельный PG block на ключ (напр. `conversation_settings.timezone`), conditional resolver; не сваливать в `response_format` — [turn-prompt](../turn-prompt.md).
6. Wiki — секция на [conversation-settings](../envelope/conversation-settings.md); work-issue.

---

## Стратегии типа answer

### A. Полное совпадение (omit / set / clear)

Storage: `field: T | null`. Answer: `field?: T | null`.

```ts
type AnswerConversationSettings = Partial<
  Pick<ConversationSettings, 'timezone'>
>;
```

Подходит, если все три операции на wire = как в storage. **Сейчас:** `timezone`.

### B. Set без clear с модели

Storage: `field: T | null`. Answer: `field?: T` (без `null`).

`Pick` даст лишний `| null` — **не использовать** для этого ключа. Описать поле отдельно:

```ts
type AnswerConversationSettings = {
  timezone?: string | null;
  otherField?: string; // без null — clear только через UI
};
```

Тип значения брать из `ConversationSettings['otherField']` (`NonNullable<…>` на wire). Когда ключей несколько — helper `DeclareField<StorageValue, AllowReset>` (см. ниже).

```ts
type DeclareField<
  StorageValue,
  AllowReset extends boolean,
> = AllowReset extends true
  ? NonNullable<StorageValue> | null
  : NonNullable<StorageValue>;

type AnswerConversationSettings = {
  timezone?: DeclareField<ConversationSettings['timezone'], true>;
  otherField?: DeclareField<ConversationSettings['otherField'], false>;
};
```

### C. Другой wire-тип, чем storage

Редко (другая форма на wire). Отдельный тип + mapper в apply; **не** `Pick`.

---

## Rejected

- `Partial<ConversationSettings>` на answer — тянет transport-only поля.
- Дублировать zod «на глаз», расходящийся с declare-типом.
- Server-side «explicit signal» вместо prompt policy для «когда слать ключ».
