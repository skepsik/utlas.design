# Атомарный turn — разобранное и открытое

Companion к [Атомарный turn: тезисы](./Атомарный%20turn.md).

**Концепт**, не план реализации. Рассинхрон терминов с кодом и [turn-pipeline](../turn-pipeline.md) пока **игнорируем**.

См. также: [native tool calls](../tools/native-tool-calls.md), [llm-jobs](../llm-jobs.md).

---

## Зачем

Зафиксировать **вопросы и тезисы**, которые обсуждались при формулировке [Атомарный turn](./Атомарный%20turn.md) (июль 2026). Не протокол интервью — только то, что важно для design, без привязки к чату.

---

## Единица и триггеры

### Почему не «turn = цепь LLM»?

Длинный turn с внутренними фазами (compose → LLM → tool loop → re-LLM → declare → deliver) порождал лишние оси:

- recall **внутри** turn или **снаружи**
- necommitted / committed, abort с «половиной side effects»
- supersede на **всю цепь**, а не на один вызов
- соблазн provider `messages[]` и native tools как «нативного» tool loop

**Тезис:** единица = **один generative pass** (inference + `toolCalls` в ответе). Многофазность — **очередь триггеров** в оркестраторе.

### Почему не orphan LLM без триггера?

**Вопрос:** tool loop = несколько LLM подряд — это несколько turn'ов без user message?

**Тезис (отвергнуто):** pass без триггера — «recall-turn без триггера» недопустим; причина быть turn'ом — **триггер**.

**Тезис (принято):** триггеры **равноправны** — user message **или** output предыдущего inference (tool → recall). Триггер N+1 = output N (или user). **Не** один общий триггер на всю цепь — хранить уродливо.

### Как связаны pass'ы одной работы без общего turn-id?

**Вопрос:** без сцепки turn'ов recall теряет контекст?

**Тезис:** inference-**получатель** ссылается на inference-**заказчика** (user message, tools того pass'а). Жёсткой цепи нет; связь — **накопленный контекст** (prompt machine) + provenance metadata оркестратора. Атомарность ≠ непрозрачность.

---

## Tool loop как цепочка pass'ов

Wire kanon и **Rejected** native / multi-message — [native-tool-calls.md](../tools/native-tool-calls.md). Здесь — только следствия для атомарного turn.

### Несколько inference подряд

**Вопрос:** tool loop = несколько LLM — это одна цепь или очередь pass'ов?

**Тезис:** **очередь pass'ов** с локальными триггерами. Каждый hop = **re-compose** + новый inference; envelope `toolCalls`, inject в compose; цепочка у **orchestrator**, не у vendor thread.

### Recall, concurrency, долгие job'ы

**Вопрос:** recall LLM + supersede + long-running job ломают атомарность?

**Тезис:** **нет.** Inference = **точка** ([llm-jobs](../llm-jobs.md)); wait — orchestrator. Supersede = ignore stale response + новый compose (cancel опционален). Job = async `{ job_id }` + callback как **новый триггер**, не blocking pass.

### Меняется ли orchestration?

**Тезис:** форма prompt та же; меняется **кто и когда** зовёт compose — **очередь триггеров**.

---

## Supersede и burst

### Граница supersede

**Вопрос:** первый токен streaming или finish?

**Тезис:** **finish.** Deliver до завершённого inference невозможен — нечего доставлять. Partial stream в egress не используем.

### Abort провайдера

**Вопрос:** supersede зависит от cancel in-flight HTTP?

**Тезис:** **нет** как архитектурная зависимость. Политика: ответ superseded pass **игнорируется**, compose обновляется, шлётся следующий inference.

### Burst vs supersede

**Вопрос:** атомарный turn ломает склейку нескольких user-сообщений?

**Тезис:** **нет** — те же правила узкого окна supersede. В пачку — только то, что уложилось в окно; следующее — в history + новый USER_MESSAGE. Burst (накопление входа) и supersede (отмена в полёте) — **разные механизмы**.

**Вопрос:** два unrelated вопроса в burst?

**Тезис:** вне окна supersede не склеятся; prompt policy — внимание на **всю пачку** внутри окна.

---

## Оркестратор, job'ы, group

### Job callback

**Вопрос:** callback «прерывает» диалог?

**Тезис:** диалог **непрерывен**; callback = триггер **продолжения цепочки**, на которую подписался pass, запустивший job. Не вклинивание в чужую нить.

### Group: параллельные ответы

**Вопрос:** лавина reply разным участникам?

**Тезис:** каждый **явно** триггерит бота; reply_to каждому — как сейчас. **Parallel compute, serial commit** в общую ленту: инференсы для разных триггеров могут идти параллельно; фиксация в ленту сериализуется по времени; отмены нет — оба ответа валидны. **Open:** гонка «второй получил ответ раньше первого» (burst первого) — ordering/UX, не корректность модели.

### Очередь vs monolith

**Вопрос:** цена атомарной модели?

**Тезис:** дополнительная **очередь триггеров** vs monolith `runTurn` — главное инженерное усложнение; детали — open.

---

## Commit и side effects

**Вопрос:** что первое **необратимое** после finish inference?

**Тезис (идея):** необратимое — **HITL-gated**; до commit-point supersede «чистый» (read + inference only). **Open:** порядок `finish → parse → tool execute → write (pin, PG, egress) → deliver` — что считается write и отменяемо ли pin до deliver.

---

## Открытые вопросы

### Очередь recall vs user

Тезис из [Атомарный turn](./Атомарный%20turn.md): recall **после** user-триггеров на момент рождения; позиция **фиксирована**.

**Нужно смоделировать** (узкие окна):

```text
U1 → P1 → tool → enqueue R
U2 до старта R — R всё ещё за U1, U2 за R?
supersede во время R / P2
```

### Deferred triggers

Тезис: проигравший триггер **откладывается**, tool output в prompt machine не теряется.

**Open:** stale deferred recall — discard | fresh compose | dedup by key. Сценарии: user вклинился, два recall, job + user.

### Provenance и restart

- metadata pass → parent pass
- cap очереди при flood
- restart: in-memory vs persist очереди триггеров

### Timeline-таблица

| Событие | Очередь | Compose | Deliver / write |
| ------- | ------- | ------- | --------------- |
| user message | | | |
| inference finish | | | |
| tool → recall enqueue | | | |
| supersede | | | |
| job callback | | | |

---

## Разобрано (итог)

- turn = **один inference**; цепочка = **очередь триггеров**
- tool loop = **несколько pass'ов** с локальными триггерами, re-compose
- supersede до **finish**; stale response **ignore**
- burst ≠ supersede; job async + handle; callback = триггер своей цепочки
- group: explicit trigger, reply_to; **parallel compute, serial commit** в ленту

---

## Rejected

| Тезис | |
| ----- | - |
| Turn = одна LLM-цепь с общим триггером | orphan recall, тяжёлый supersede |
| Orphan pass без триггера | нет триггера — не turn |
| Supersede требует native abort | ignore stale response |
| Callback = прерывание чужого диалога | callback = своя подписанная цепочка |

---

## Вне scope

- синхронизация термина **turn** с кодом
- страница **prompt machine**
- миграция v0 → orchestrator
