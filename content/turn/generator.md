# Generator

**Black box одного turn:** LLM, tools, in-memory пакет turn; **yield** этапов наружу и **return** полного snapshot для persist.

---

## Зачем

Изолировать **генерацию** от delivery (wire) и persist (flush). Black box: на входе **готовые** `prompt` и **anchor context**; внутри — LLM и tools; на выходе — yield этапов и return snapshot.

---

## Границы

### Generator **знает** и **делает**

| Область | Смысл |
| -------- | ----- |
| **Вход** | `ComposedPrompt`, `AnchorContext`, `AbortSignal` |
| **LLM** | invoke (adapter/router внутри), parse `LlmAnswer`, recall (v1: ≤2 вызова) |
| **Tools** | invoke по `ToolCall` от модели, сырой `result` (execute) |
| **Steps** | накопление `steps[]`: llm-строки (`result`, `shouldReply`, `conversationSettings` из **того** `LlmAnswer`) + tool (call + optional `result`) |
| **Yield** | `TurnStepResult` / `TurnStepSignal` / `TurnLifecycleSignal` |
| **Return** | `{ steps }` — snapshot для flush transcript |

`shouldReply` / `conversationSettings` на llm-строке — **факты ответа модели**, не решение «wire или нет».

### Generator **не знает** и **не делает**

| Область                                     | Кто                                 |
| ------------------------------------------- | ----------------------------------- |
| Сборка / enrich prompt, CHAT HISTORY        | upstream (compose до generator)     |
| Wire, transport, Telegram API               | downstream (orchestrator на yield)  |
| **history / ephemeral**                     | downstream (outbound policy)        |
| **decompose**, formatter tool → ячейки чата | downstream (registry на wire/flush) |
| Таблица **`messages`**, derive chat history | flush после wire                    |
| **`turn_outputs`** колонки кроме transcript | flush (derive из steps + input)     |
| Wire receipts, transport message ids        | downstream                          |
| Flush PG                                    | отдельный шаг после return          |
|                                             |                                     |

### Граница yield / return

- **Yield** — «шаг готов»; downstream **может** wire / UI.
- **Return** — `{ steps }` для persist transcript; **не** дублирует `messages`.

Generator **не** пишет в PG и **не** вызывает outbound.

---

## Термины

| Термин             | Смысл                                                                                                                    |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| **Генератор**      | Компонент: LLM + execute tools + накопление пакета turn in-memory.                                                       |
| **TurnStepResult** | Result шага: llm/tool. Yield + элемент **`return.steps`**. |
| **TurnStepSignal** | Call signal: `llm:call`, `tool:call`. `tool:call` → stub в `steps`. |
| **TurnLifecycleSignal** | Границы turn: `turn:started`, `turn:finished`, `turn:aborted`. Не в `steps`. |
| **Yield**          | Генератор отдал этап; downstream может реагировать (wire, UI, …).                                                        |
| **Return**         | Финальный snapshot пакета turn после завершения генератора.                                                              |
| **Anchor context** | Минимальный контекст trigger-сообщения turn: id, conversation, transport, … — всё, что нужно генератору для LLM и tools. |
| **Prompt**         | Готовый **структурированный** composed prompt (секции / slots); генератор **не** собирает prompt. Строки для API — только в LLM-adapter. |
| **Пакет turn**     | In-memory `{ steps }`, тот же shape что **return**. |
|                    |                                                                                                                          |

---

## Сигнатура

```ts
type PromptSection = {
  key: string;
  body: string;
};

type PromptHalf = {
  sections: PromptSection[];
};

/** Результат compose — наш формат; не wire API провайдера. */
type ComposedPrompt = {
  system: PromptHalf;
  user: PromptHalf;
};

type AnchorContext = {
  anchorId: string;
  conversationId: string;
  transport: string;
};

type GeneratorInput = {
  anchor: AnchorContext;
  prompt: ComposedPrompt;
  signal?: AbortSignal;
};

type Generator = {
  run(input: GeneratorInput): AsyncGenerator<GeneratorYield, GeneratorReturn>;
};
```

- **Вход:** `prompt` + `anchor` (+ optional `signal`). `prompt` — **секции**, не склеенные `system`/`user` строки.
- **Выход:** **yield** `TurnStepResult` / `TurnStepSignal` / `TurnLifecycleSignal`; **return** — `{ steps }`.
- Вызывающий код передаёт **готовый** composed prompt; генератор **не** знает, откуда он взялся.
- **LLM внутри генератора:** adapter провайдера преобразует `ComposedPrompt` → формат API (join секций, `messages`, structured output schema, …). Router/cascade — тоже внутри.

---

## Механика

```text
prompt + anchor context
        │
        ▼
   ┌─────────────┐
   │  Generator  │
   │  (копит     │
   │   пакет)    │
   └──────┬──────┘
          │
          ├─ yield Result | StepSignal | LifecycleSignal ──► downstream
          ├─ yield Result | StepSignal | LifecycleSignal ──► downstream
          │
          └─ return snapshot
```

1. Генератор получает `GeneratorInput`, вызывает LLM; adapter сериализует `ComposedPrompt` для провайдера.
2. После каждого **`llm:call`** → **yield** `TurnStepLlmResult` + append (`result` может быть `''`).
3. Завершённый tool → **yield** `TurnStepResult` tool + **`result`** в запись.
4. Перед LLM → **yield** `TurnStepSignal` `llm:call`. **`tool:call`** → signal + stub в `steps`.
5. Завершение — **return** `{ steps }`.

**Return** — snapshot turn для flush; **`messages`** (chat history) downstream **derive** из steps + registry + wire policy — не отдельное поле return.

См. **Tool loop (v1)**.

---

## Типы

```ts
import type { LlmAnswer } from '@utlas/core/llm';

/** Запрос tool от модели. `arguments` — z.infer discriminated union по `name` (@utlas/core/llm/tool-calls). */
type ToolCall = {
  arguments: unknown;
  name: string;
};

/** Generic `{ kind }` — building block для signal и result. */
type TurnStepOf<K extends string> = { kind: K };

type TurnStepResultOf<K extends string, R = unknown> = TurnStepOf<K> & {
  result: R;
};

/** Tool: call + optional result (одна запись на invoke). */
type TurnStepToolResult = TurnStepOf<'tool'> & ToolCall & {
  result?: unknown;
};

/** LLM: text + поля того же `LlmAnswer` (zod `@utlas/core/llm/answer`). */
type TurnStepLlmResult = TurnStepResultOf<'llm', string> & {
  conversationSettings?: LlmAnswer['conversationSettings'];
  shouldReply: LlmAnswer['shouldReply'];
};

/** Result yield + элемент `steps`. */
type TurnStepResult = TurnStepLlmResult | TurnStepToolResult;

/** Call signal — до result (instrument). */
type TurnStepSignal =
  | TurnStepOf<'llm:call'>
  | (TurnStepOf<'tool:call'> & ToolCall);

/** Lifecycle turn — не instrument, не в `steps`. */
type TurnLifecycleSignal =
  | TurnStepOf<'turn:aborted'>
  | TurnStepOf<'turn:finished'>
  | TurnStepOf<'turn:started'>;

type GeneratorYield =
  | TurnLifecycleSignal
  | TurnStepResult
  | TurnStepSignal;

/** Return — snapshot turn; turn-level поля — позже. */
type GeneratorReturn = {
  steps: TurnStepResult[];
};
```

**`TurnStepSignal`** — call (`llm:call`, `tool:call`). **`TurnLifecycleSignal`** — границы turn. **`GeneratorYield`** — union трёх.

- **Return** — `{ steps: TurnStepResult[] }`; расширяемый wrapper.
- Llm-строка: **всегда** после `llm:call`; `result` — `LlmAnswer.text` (в т.ч. `''`); `shouldReply` + `conversationSettings?` из того же ответа. Wire — downstream.

`GeneratorYield` — payload **yield**. `GeneratorReturn` — **return** (snapshot для persist).

---

## `llm` vs `tool` TurnStepResult

Различие — **источник**, не «виден ли текст в чате».

| | `kind: 'llm'` | `kind: 'tool'` |
| --- | --- | --- |
| Откуда | `LlmAnswer.text` | execute tool → сырой `result` |
| Shape | `TurnStepLlmResult` | `TurnStepToolResult` |
| Поля llm | `result`, `shouldReply`, `conversationSettings?` — из **этого** `LlmAnswer` | `name`, `arguments`, `result?` |
| Downstream | wire по `shouldReply` этой строки; apply settings с этой строки | decompose, wire, `messages` |

Generator отдаёт **instrument + output**; history/ephemeral, decompose, formatter — **не** в generator.

---

## Tool loop (v1)

**v1:** максимум **два** LLM-вызова за turn — начальный + **один** recall **только в конце** цикла tools (не N раундов).

**Порядок yield (v1)** — слева направо; `?` у tool — только если invoke не дал `result` (TBD fail):

| # | `GeneratorYield` | `steps` |
| - | ---------------- | ------- |
| 1 | `TurnLifecycleSignal` `{ kind: 'turn:started' }` | — |
| 2 | `TurnStepSignal` `{ kind: 'llm:call' }` | — |
| 3 | `TurnStepLlmResult` | append |
| 4 | `TurnStepSignal` `{ kind: 'tool:call' }` … | stub tool |
| 5 | `TurnStepResult` tool? | `result` в ту же запись |
| 4–5 | … для каждого tool | … |
| 6 | `TurnStepSignal` `{ kind: 'llm:call' }` (recall) | — |
| 7 | `TurnStepLlmResult` | append |
| 8 | `TurnLifecycleSignal` `{ kind: 'turn:finished' }` | — |
| — | **`return`** `{ steps }` | snapshot |

**Policy:** 1-й инференс: `TurnStepLlmResult` **всегда**; если ещё и tools — выполняем tools; затем recall.

**Пример** («где офис?») — та же схема; Wire — только то, что видит пользователь:

| Wire (после downstream) | GeneratorYield |
| ----------------------- | -------------- |
| «где офис?» | (вход turn) |
| — | `TurnLifecycleSignal` `turn:started` |
| — | `TurnStepSignal` `llm:call` |
| «пойду поищу» | `TurnStepLlmResult` (1-й LLM) |
| — | `TurnStepSignal` `tool:call` geocoder (+ stub в `steps`) |
| — | `TurnStepResult` tool geocoder (`result`) |
| — | `TurnStepSignal` `tool:call` map pin (+ stub) |
| map pin | `TurnStepResult` tool map pin (`result`) → downstream wire |
| — | `TurnStepSignal` `llm:call` (recall) |
| «отобразил на карте» | `TurnStepLlmResult` (2-й LLM) |
| — | `TurnLifecycleSignal` `turn:finished` |
| — | `return { steps }` |

Без tools — recall не делаем; один LLM, один `TurnStepResult` llm по policy.

---

## Yield

| Yield | Когда | Пакет |
| ----- | ----- | ----- |
| `TurnStepSignal` `llm:call` | перед инференсом (≤2 в v1) | — |
| `TurnStepResult` `llm` | после каждого `llm:call` | append `TurnStepLlmResult` (`result` в т.ч. `''`) |
| `TurnStepSignal` `tool:call` | начало invoke tool | stub `{ kind: 'tool', … }` |
| `TurnStepResult` `tool` | tool отработал | `result` в ту же запись |
| `TurnLifecycleSignal` | started / finished / aborted | — |

Yield **`TurnStepResult`**, **`TurnStepSignal`**, **`TurnLifecycleSignal`** — downstream реагирует (wire, UI, …). В **`steps`** только results (llm; tool stub на `tool:call`, `result` на success). Lifecycle **не** в `steps`. Генератор **не** пишет в PG на yield.

---

## In-memory пакет

Генератор владеет одним объектом пакета на turn:

| Часть пакета | Когда пополняется |
| ------------ | ----------------- |
| `steps` | llm append; tool stub + `result` |

К моменту **return** пакет **полный** и **неизменяемый** с точки зрения генератора.

---

## Return

Return — **`GeneratorReturn`** (`{ steps }`):

- `steps` → transcript `turn_outputs`;
- колонки turn (`shouldReply`, settings) — **derive** flush из llm-строк (правило — TBD);
- **`messages`** — derive downstream + registry + wire.

Один snapshot → один flush. Consumer **не** копит второй массив на yield'ах.

---

## Сейчас vs цель

| Аспект | Сейчас (v0) | Цель |
| ------ | ----------- | ---- |
| Prompt на вход LLM | `LlmPrompt { system, user }` — строки уже в composer (`buildSection`) | `ComposedPrompt` — секции; join → только в adapter |
| LLM steps за turn | один вызов | **v1:** ≤2 (начальный + один recall после tools) |
| Накопление пакета | смешано с delivery в одном модуле | generator — отдельный black box |
| Return | частично размазан по accumulator | `{ steps: TurnStepResult[] }` |

---

## Открытые вопросы

- **Failed tool:** stub без `result`, или **`result` = error** — TBD.
- **`turn_outputs.shouldReply` / settings:** final llm vs merge — TBD (данные уже на каждой llm-строке).

---

## Инварианты (не менять без ADR)

- Генератор **yield'ит** `GeneratorYield` (result + call signal + lifecycle).
- **Return** — `{ steps }` для flush.
- **`shouldReply` / `conversationSettings`** — на **`TurnStepLlmResult`**, не flat metadata.
- Persist **`messages`** — derive downstream, не поле return.
- **`TurnStepLlmResult`** — **всегда** после `llm:call`; `result` = `LlmAnswer.text` (может быть `''`). Молчание модели — downstream.
- **Tool invoke:** одна запись в `steps` на `tool:call`; `result` — после success (1:1).
- **Recall LLM (v1):** не больше одного, только после tools.
- 1-й инференс с tools → `TurnStepLlmResult` (в т.ч. пустой `result`) **и** tools.

- **Prompt** на входе — структурированный (`ComposedPrompt`); сериализация в строки API — **только** LLM-adapter.

---

## Rejected

### Return как голый `TurnStepResult[]`

**Не делаем:** без wrapper сложнее добавить turn-level поля (`status`, `outputId`, …).

### Flat `metadata` в return

**Не делаем:** при ≤2 LLM неясно, чей `LlmAnswer`; поля живут на **`TurnStepLlmResult`**.

### `historyMessages` / `persistMessages` в return

**Не делаем:** дубль steps; flush derive + registry + wire policy.

### Отдельный `toolCalls[]` в return

**Не делаем:** параллельный массив; call + result — одна запись `TurnStepToolResult`.

### Fat `finished` с полным `LlmAnswer`

**Не делаем:** дублирует steps; lifecycle — `TurnLifecycleSignal` без payload.

### Persist-очередь на yield'ах у consumer

**Не делаем:** второй накопитель у orchestrator/delivery; расходится с пакетом генератора.

### Wire / transport внутри генератора

**Не делаем:** генератор не вызывает delivery и не знает egress; только yield.

### Flush PG внутри генератора

**Не делаем:** persist — отдельный шаг после return.

---

## Out of scope

См. **Границы** — delivery, persist PG, compose prompt, history/ephemeral, decompose для wire.

---

## Later

- **Tool loop v2+:** несколько recall LLM; контракт yield-типов тот же.
- Inject из `return.steps` в `ComposedPrompt` перед recall.
- **LLM как instrument:** `TurnStepSignal` `llm:call` + `TurnStepResult` `llm`; tool — `tool:call` + `TurnStepResult` `tool`. Registry — TBD.
