# Атомарный turn — разобранное и открытое

Companion к [Атомарный turn: тезисы](./Атомарный%20turn.md).

**Концепт**, не план реализации; рассинхрон терминов с кодом и [turn-pipeline](../turn-pipeline.md) пока **игнорируем**.

См. также: [native tool calls](../tools/native-tool-calls.md) (wire blob), [llm-jobs](../llm-jobs.md) (invoke vs обработка), [semantic-thread](../semantic-thread.md) § Подача модели.

---

## Разобрано

Вопросы из первого design-review (2026-07); статус на момент текста.

### Supersede и streaming

**Вопрос:** граница supersede — первый токен или finish?

**Решение:** для нас **finish**. Deliver раньше завершённого inference невозможен — нечего доставлять. Partial stream в egress не используем; ответ = завершённый fetch + parse.

### Abort in-flight inference

**Вопрос:** нужен ли рабочий cancel у провайдера?

**Решение:** **нет** как архитектурная зависимость. Cancel signal можно послать; политика та же, что сейчас: **ответ superseded inference игнорируем**, compose обновляем, шлём следующий. Supersede не ждёт физического abort.

### Wire prompt и prompt machine

**Вопрос:** меняется ли форма промпта (blob vs multi-message)?

**Решение:** **нет.** Один `{ system, user }`, секции compose прежние. Меняется **кто и когда** вызывает compose (оркестратор, очередь триггеров), не envelope wire. Multi-message и native tools — [Rejected](../tools/native-tool-calls.md).

### Burst и supersede

**Вопрос:** ломает ли атомарность склейку нескольких user-сообщений?

**Решение:** **нет** — поведение как сейчас в узком окне supersede. В одну пачку попадает только то, что уложилось в окно; следующее сообщение — уже в history + новый USER_MESSAGE. Policy в prompt: модель смотрит на **всю пачку**.

### Job callback «посреди диалога»

**Вопрос:** не прерывает ли callback UX?

**Решение:** метафора «посреди» неверна. Диалог **непрерывен**; callback = триггер **продолжения цепочки**, на которую подписался pass, запустивший job (deploy и т.п.). Не случайное вклинивание в чужую нить.

### Group: параллельные ответы

**Вопрос:** лавина ответов в шумном чате?

**Решение:** каждый участник **явно** триггерит бота; ответ с reply_to — как сейчас. Теоретическая гонка «второй получил ответ раньше первого» (burst первого) — ordering/UX; корректность модели не ломает. Детали — § Открытые вопросы.

### Плюсы sketch'а (зафиксированы)

- inference **атомарен**; ожидание — у **оркестратор**
- долгие действия — **async job** + handle в conversation-state
- supersede = длительность **одного** inference (до finish)
- burst и supersede — **разные** механизмы
- необратимое — **HITL-gated** commit-point (идея; детали — open)
- сложность provider chain (`messages[]`, native tools) — **не** переносим

---

## Открытые вопросы

### Очередь recall vs user-триггеры

Правило: recall встаёт **после всех user-триггеров на момент рождения**; позиция фиксируется.

**TBD:** timeline при **узких** окнах — recall уже в очереди, приходит **следующий** user-триггер: он строго **после** recall или может опередить? Симуляция на реальных интервалах (не synthetic flood).

### Deferred / stale triggers

«Проигравший триггер **откладывается**» — output tools в prompt machine, не теряется.

**TBD:** кейсы, когда отложенный recall **устарел** по смыслу (discard? dedup? always run with fresh compose?). Таблица сценариев: вклинивание user / job / второй recall.

### Commit-point и side effects tools

**TBD:** упорядочение относительно finish inference:

```text
inference finish → parse → tool execute → ??? write (pin, PG, egress) → deliver
```

Что считается **первым необратимым write**? Pin до deliver — отменяемо ли при supersede следующего pass? Связь с HITL-gate. (В [Атомарный turn](./Атомарный%20turn.md) отложено осознанно.)

### Group ordering при burst

**TBD:** два участника триггерят бота; первый burst'ит — второй получает ответ раньше. Моделирование latency + очереди; нужны ли product-ограничения (не блокер архитектуры).

### Очередь триггеров и операционка

Дополнительная очередь vs monolith `runTurn` — **главное** инженерное усложнение.

**TBD:**

- cap длины очереди / flood
- provenance «inference-получатель → inference-заказчик» (wire metadata)
- **restart:** персистентная очередь триггеров vs in-memory (упомянуто в тезисах как «если понадобится»)

### Timeline (следующий артефакт)

Одна таблица для моделирования (приоритет перед глоссарием):

| Событие | Очередь | Compose snapshot | Deliver / write |
| ------- | ------- | ---------------- | --------------- |
| user message | … | … | … |
| inference finish | … | … | … |
| tool result → recall enqueue | … | … | … |
| supersede | … | … | … |
| job callback | … | … | … |

### Вне scope этого документа

- синхронизация термина **turn** с кодом / [turn-pipeline](../turn-pipeline.md)
- оформление **prompt machine** как отдельная страница
- миграция с v0 monolith

---

## Rejected (review)

- **Provider `messages[]`** как канon — см. [native-tool-calls](../tools/native-tool-calls.md)
- **Зависимость supersede от native abort** — см. § Abort выше
- **«Mid-dialog» callback** как прерывание — см. § Job callback выше
