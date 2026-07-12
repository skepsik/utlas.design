# Атомарный turn — разобранное и открытое

Companion к [Атомарный turn: тезисы](./Атомарный%20turn.md).

**Концепт**, не план реализации; рассинхрон терминов с кодом и [turn-pipeline](../turn-pipeline.md) пока **игнорируем**.

См. также: [native tool calls](../tools/native-tool-calls.md), [llm-jobs](../llm-jobs.md).

---

## Зачем этот документ

Тезисы в [Атомарный turn](./Атомарный%20turn.md) родились быстро (обсуждение с Claude, июль 2026). Здесь — **конкретные вопросы, аргументы за/против и итоги**, чтобы не терять контекст при закрытии чата. Не ссылка на сессию, а **сжатая стенограмма решений**.

---

## Обсуждение A: от «turn = цепь LLM» к «turn = один inference»

### A1. Что было не так со старой моделью?

**Боль:** turn как длинная скобка с фазами (compose → LLM → tool loop → re-LLM → declare → deliver) порождал:

- «recall внутри turn или снаружи?»
- necommitted / committed, abort с «половиной side effects»
- supersede на всю цепь, а не на один вызов
- соблазн **provider `messages[]`** и native tools как «нативного» tool loop

**Итог:** единица сведена к **одному generative pass** (inference + его `toolCalls` в ответе). Многофазность — **очередь триггеров в оркестраторе**, не внутренности одного turn'а.

### A2. Почему не «turn = каждый LLM-вызов без триггера»?

**Вопрос:** tool loop = несколько LLM подряд — это несколько turn'ов?

**Отвергнуто:** turn без собственного триггера (orphan LLM) — «recall-turn без триггера» как text без payload.

**Принято:** триггеры **равноправны**:

- user message
- output предыдущего inference (tool result → recall)

Цепочка: триггер N+1 = output N (или user). **Не** «один исходный триггер на всю цепь» — общий триггер на всю цепь хранить уродливо.

### A3. Как связаны проходы одной «работы»?

**Вопрос:** если нет общего turn-id, как recall знает контекст?

**Ответ (тезис):** inference-**получатель** ссылается на inference-**заказчика** (какой user message, какие tools). Provenance — metadata оркестратора; жёсткая сцепка turn'ов — нет. Следующий pass видит **накопленный контекст** (prompt machine), атомарность ≠ непрозрачность.

**Open:** wire provenance — § ниже.

---

## Обсуждение B: wire, tool loop, native / multi-message

Связано с [native-tool-calls.md](../tools/native-tool-calls.md); здесь — **почему** это стыкуется с атомарным turn.

### B1. Multi-message упрощает большое окно?

**Нет.** Те же токены, те же проблемы (group, supersede, очередь). Multi-message только меняет упаковку; overhead role/part может быть **выше**, чем у blob. Размер окна (~100 msg) — **не аргумент** за/против multi-message.

### B2. Multi-message для нескольких inference подряд ⇒ tool calls?

**Да, если** растить provider `messages[]` между hop'ами — нужны tool-shaped слоты между `assistant` hop'ами.

**Наш путь:** **re-compose blob** на каждый pass; цепочка у **orchestrator**, не у vendor thread. Envelope `toolCalls` + inject в compose ([tool loop](../tools/native-tool-calls.md) § Wire kanon). Native tools — **Rejected**.

### B3. Recall LLM + concurrency ⇒ native tools?

**Изначальный страх:** recall, supersede, долгие job'ы «тянут» native tool API.

**Итог:** native **не нужен**. Достаточно:

- inference = **точка** (`llmInvoke`-стиль, [llm-jobs](../llm-jobs.md))
- ожидание tool / job — **orchestrator**
- supersede = игнорировать ответ + новый compose (cancel signal опционален)

Долгий job: `{ job_id }` в conversation-state; callback = **новый триггер**, не blocking inference.

### B4. Group: `user-user-user` в multi-message?

**Проблема:** API требует чередование user/assistant → burst людей **склеивают** в один `user` → API врёт («один user turn»), speaker только из текста.

**Итог:** ещё один аргумент **против** multi-message в group. Blob честнее: все speaker'ы в content с одинаковой грамматикой `[Alice]:` / `(bot)`.

### B5. Меняется ли prompt?

**Нет.** Один `{ system, user }`, те же секции compose. Меняется **кто и когда** зовёт compose (очередь триггеров), не wire.

---

## Design-review атомарного turn (2026-07)

Формат: **вопрос ревью → ответ оператора → статус**.

### C1. Supersede: первый токен или finish?

| | |
|--|--|
| **Ревью** | При streaming граница размыта |
| **Ответ** | Deliver **до** ответа невозможен. Partial stream в egress нет. Граница = **finish** fetch + parse |
| **Статус** | **Закрыто** |

### C2. Нужен ли abort у провайдера?

| | |
|--|--|
| **Ревью** | Supersede зависит от cancel in-flight |
| **Ответ** | Как **сейчас**: cancel шлём, но можно **игнорировать** ответ superseded inference и слать следующий compose |
| **Статус** | **Закрыто** — abort не несёт архитектуру |

### C3. Recall в очереди vs новый user-триггер

| | |
|--|--|
| **Ревью** | Новое сообщение после enqueue recall, до старта recall — кто первый? |
| **Ответ** | Окна **узкие**; recall стоит **за** user-триггером на момент рождения; следующий user — **за** recall (гипотеза, нужна симуляция) |
| **Статус** | **Open** — timeline |

### C4. Deferred trigger устарел

| | |
|--|--|
| **Ревью** | «Отложить, не выбросить» → stale recall |
| **Ответ** | Согласен, **кейсы разрисовать** (discard / dedup / always fresh compose) |
| **Статус** | **Open** |

### C5. Commit-point и tool side effects

| | |
|--|--|
| **Ревью** | Pin / write до deliver — отменяемо при supersede? |
| **Ответ** | «Не понял» — уточнение ревью: вопрос про порядок `inference finish → tool execute → write → deliver`, не про deliver до ответа. HITL-gate — идея границы необратимого |
| **Статус** | **Open** — список первого write |

### C6. Job callback «посреди диалога»

| | |
|--|--|
| **Ревью** | Callback прерывает UX |
| **Ответ** | Диалог **вечен**; callback = триггер цепочки, на которую **подписался** pass с deploy. Не чужая нить |
| **Статус** | **Закрыто** |

### C7. Group: лавина ответов

| | |
|--|--|
| **Ревью** | Параллельные ответы разным людям — шум |
| **Ответ** | Явный trigger + reply_to каждому; как сейчас. Гонка «второй ответил раньше» — ordering, не корректность |
| **Статус** | **Open** — моделирование latency |

### C8. Burst: два вопроса в одной пачке

| | |
|--|--|
| **Ревью** | Склейка unrelated messages |
| **Ответ** | Как **сейчас** в окне supersede: не склеятся, если второе **вне** окна — первое в history, второе в USER_MESSAGE; prompt на всю пачку |
| **Статус** | **Закрыто** для v0-логики |

### C9. Prompt machine — новая логика?

| | |
|--|--|
| **Ревью** | Single point of failure |
| **Ответ** | Prompt **тот же**; меняется orchestration, не форма |
| **Статус** | **Закрыто** (отдельная страница prompt machine — later)

### C10. Очередь vs monolith

| | |
|--|--|
| **Ревью** | Операционная сложность |
| **Ответ** | Да, **главное** усложнение vs `runTurn`; разбирать глубже |
| **Статус** | **Open** |

---

## Разобрано (сводка)

- inference **атомарен** до finish; deliver после ответа
- supersede = игнор stale response + новый compose; abort provider **не обязателен**
- wire = **blob**; multi-message + native tools — **Rejected**
- tool loop = **несколько pass'ов** с локальными триггерами, re-compose
- burst ≠ supersede; job = async + handle; callback = триггер своей цепочки
- group: explicit trigger, reply_to; parallel compute, serial commit в ленту

---

## Открытые вопросы (сводка)

### Очередь recall vs user

Правило из тезисов: recall **после** user-триггеров на момент рождения; позиция **фиксирована**.

**Нужно смоделировать:**

```text
T0  user U1 → inference P1 стартует
T1  P1 finish → tool → enqueue recall R (за U1)
T2  user U2 (до старта R?) → R всё ещё за U1, U2 за R?
T3  supersede во время P2 / R — кто отменяется?
```

### Deferred / stale triggers

Сценарии для таблицы:

- user вклинился → recall deferred → контекст уже другой
- два recall в очереди
- job callback + user одновременно

Политика: **discard** | **run with fresh compose** | **dedup by trigger key** — TBD.

### Commit-point

```text
inference finish → parse → tool execute → ??? pin/PG/egress → deliver
```

Первый **необратимый** write; связь с HITL. Pin до deliver — в отменяемой фазе или нет?

### Group ordering

Два user'а, первый burst'ит дольше — второй может получить reply раньше. Product-лимиты? Только моделирование?

### Очередь и restart

- cap очереди при flood
- provenance pass → parent pass (metadata)
- restart процесса: in-memory vs persist очереди триггеров

### Timeline-таблица (следующий артефакт)

| Событие | Очередь | Compose snapshot | Deliver / write |
| ------- | ------- | ---------------- | --------------- |
| user message | | | |
| inference finish | | | |
| tool → recall enqueue | | | |
| supersede | | | |
| job callback | | | |

Приоритет **перед** глоссарием терминов.

---

## Rejected (из обсуждений)

| Идея | Почему |
| ---- | ------ |
| Provider `messages[]` как канон | [native-tool-calls](../tools/native-tool-calls.md); chain + group burst |
| Native tools API | envelope `toolCalls` + re-compose достаточно |
| Supersede зависит от native abort | ignore stale response |
| «Callback посреди чужого диалога» | callback = своя подписанная цепочка |
| «Большое окно ⇒ multi-message» | не упрощает; те же tok |
| Turn = одна LLM-цепь с общим триггером | orphan recall, сложный supersede |
| Orphan LLM pass без триггера | нет триггера — не turn |

---

## Вне scope

- синхронизация **turn** с кодом / [turn-pipeline](../turn-pipeline.md)
- страница **prompt machine**
- миграция v0 monolith → orchestrator
