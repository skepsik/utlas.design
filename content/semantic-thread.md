# SemanticThread

Hub — [domain](./domain/) § SemanticThread.

---

## Сейчас vs цель

| | Сейчас (v0) | Цель |
|---|-------------|------|
| Сборка | `buildSemanticThread` вызывает только `MessageReadSelectors.replyChain` | Selector → Heuristic → Builder (ниже) |
| CHAT HISTORY | `selectRecentBefore` + `MessageReadSelectors.windowBefore(limit)` | отдельный selector `recentN` (design) |
| Heuristic / layered Builder | нет в коде | domain-слой поверх selectors |

---

## Что такое SemanticThread

`SemanticThread` — семантическая ветка разговора, собранная доменным сервисом из кандидатов-нод (`MessageRef`). Её задача — подсветить модели конкретный разговор на фоне общего шума чата.

В коде: тип `{ messages: MessageRef[] }` (`@utlas/core/domain/model/semantic-thread`).

`SemanticThread` ≠ reply-chain в Telegram. Reply-chain — одна из возможных эвристик, не определение понятия.

---

## Архитектура сборки

### Три слоя: Selector → Heuristic → Builder

Целевая модель (v0 — только первый слой, см. **Сейчас vs цель**):

```text
Trigger (qualifying-событие)
│
▼
Selector (storage/)     ← знает о способе хранения, не домен
│                       возвращает кандидатов (ноды)
▼
Heuristic (domain/)     ← детерминированные, возвращают claim/score
│                       оценивают каждую ноду
▼
Builder (domain/)       ← выбирает комбинацию selector+heuristic,
│                         возможны рекурсивные проходы
▼
(опционально) LLM-инференс ← финальная фильтрация кандидатов;
│                           claim/score от эвристик — подсказки
▼
SemanticThread          ← готовая собранная ветка
```

**Сейчас (v0):** `buildSemanticThread` в `@utlas/core/domain/services/build-semantic-thread` — монолитный builder: вызывает `readPort.selectors.replyChain.select({ anchor, transport })`, без отдельного Heuristic-слоя.

---

## Selector

Живёт в `storage/` — реализация напрямую связана со способом хранения, это не вопрос домена.

Контракт: `MessageSelector` — `{ id, select(ctx: SelectContext) }`; registry на порту — `MessageReadPort.selectors` (`MessageReadSelectors`).

| Селектор (цель) | Описание | Сейчас (v0) |
| ----------------- | -------- | ----------- |
| `recentN` | Последние N нод от триггера | `windowBefore(limit)` → `createWindowBeforeSelector`; доменный сервис `selectRecentBefore` для slot **CHAT HISTORY** |
| `anchorRefChain` | Цепочка по полю `MessageRef.anchorRef` от триггера | `replyChain` → `createReplyChainSelector`; slot **SEMANTIC THREAD** в `buildSemanticThread` |

TTL reply-chain: **нет** — история слепок, не устаревает. Selector в домене **не** живёт (только `storage/`).

Предполагаемые селекторы (из utlas-bot#42, частично устарело)

| Сценарий                              | Selector(s)                          | Ожидание                   |
| ------------------------------------- | ------------------------------------ | -------------------------- |
| Reply на старое со ссылкой вне окна N | `getReplyNodes`                      | ref со ссылкой в shortlist |
| Ссылка → @bot → ответ → reply на bot  | `getReplyToBotBranch`, link selector | ref со ссылкой включён     |
| @ + reply на user (fork)              | TBD selector/heuristic               | ветка с bot                |
| Burst без reply (private)             | `getOpenUtteranceNodes`              | utterance одного sender    |
| Group: дописка без @                  | `getOpenUtteranceNodes`              | same utterance (#37)       |
| Quote без reply                       | `getReplyNodes` / anchor             | excerpt + anchor           |


---

## Якорь

**Turn anchor** — `MessageRef` в `SelectContext.anchor` / `TurnRequest.anchor` (центр **USER MESSAGE** в prompt). Якорем может быть **любое сообщение** — не только user message.

**`anchorRef`** — поле `MessageRef`: transport-сигнал reply-parent; по нему ходит `replyChain` / целевой `anchorRefChain`.

Якорь определяет стартовую точку для selector `anchorRefChain`. Конкретный выбор якоря — ответственность контекста применения (Builder решает, какой selector/heuristic использовать).

---

## Эвристики

### Общий принцип: recall > precision

Лучше захватить лишнее, чем потерять нужное. Финальная фильтрация — задача LLM-шага (если он есть), а не эвристик. Векторный поиск / эмбеддинги **не** планируются.

### Возвращаемое значение: claim/score

Каждая эвристика возвращает `claim/score` — оценку релевантности ноды. Финальный score при нескольких эвристиках — см. **Открытые вопросы**.

### Типы эвристик

| Тип | Применяется к |
| --- | ------------- |
| Универсальная | Любая нода, смотрит на расположение |
| Текстовая | Текстовые сообщения |
| Документная | Сообщения с документами |

### Примеры эвристик

- Сообщение рядом по времени с триггером
- Общие обращения (к тому же пользователю / боту)
- Документ, сразу после которого началась цепочка ответов или обращение к боту
- Reply-chain по `anchorRef`

---

## Builder

- Выбор комбинации selector + heuristic — **исключительно ответственность Builder'а**
- Возможны рекурсивные проходы (точная алгоритмика — **Открытые вопросы**)
- Builder — доменный сервис, не знает о Telegram/transport

**Сейчас (v0):** роль builder выполняет `buildSemanticThread` (без выбора heuristic).

---

## LLM-фильтрация (опционально)

После всех прогонов возможен отдельный LLM-инференс для финальной фильтрации кандидатов. `claim/score` от эвристик передаются как подсказки. Builder отдаёт готовую ветку.

---

## Открытые вопросы

- Алгоритмика рекурсивных проходов Builder'а
- Сложение score двух эвристик: сумма или `max(a, b)`?
- Поведение при превышении context window
- **Supersede:** объединение SemanticThread прерванной и новой итерации turn — [turn-pipeline](./turn-pipeline.md)
- TTL по эвристикам, отличным от reply-chain (пока не проектировался)
