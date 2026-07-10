# Composite tools, цепочки и память

**Канон:** атомарные instruments в registry; модель собирает цепочки через **`composite`** в `toolCalls` или одиночные вызовы. Координаты после geocode **не** пишет модель — backend мапит по зарегистрированным рёбрам.

См. также: [tools](./index.md), [geocode](./geocode.md), [envelope](../envelope/index.md), [native-tool-calls](./native-tool-calls.md), [transport](../transport/).

**Этап 2:** [#67](https://github.com/skepsik/utlas-ts/issues/67) (`show_map_pin` + loop). **Этап 2b:** [#68](https://github.com/skepsik/utlas-ts/issues/68) (`ToolRunResult` + compose block). **Этап 3:** [#38](https://github.com/skepsik/utlas-ts/issues/38) (geocode + composite).

---

## Именование (LLM vs код)

| Слой | Имя | Зачем |
|------|-----|--------|
| **LLM tool** | `show_map_pin` | смысл для модели: «показать точку на карте» |
| **Egress port** | `OutboundPort.deliver` (`map_pin`, `text`) | transport-нейтральная доставка + persist policy |
| **Telegram** | `api.sendLocation` | только в `transport/` |
| **История (domain)** | `MessagePayload.type: "map_pin"` | discriminant payload; не путать с egress `kind` ([#128](https://github.com/skepsik/utlas-ts/issues/128)) |
| **Egress item** | `ConversationOutboundItem.kind` (`text`, `map_pin`) | transport-форма исходящего; позже `form` ([#128](https://github.com/skepsik/utlas-ts/issues/128)) |

Модели **не** светим `sendLocation` / `deliver` — только стабильные tool names в prompt.

---

## Этапы реализации

```text
1. [#65](https://github.com/skepsik/utlas-ts/issues/65)  egress: `deliver` map_pin + persist
2. [#67](https://github.com/skepsik/utlas-ts/issues/67)  show_map_pin + toolCalls + minimal loop (простой tool result JSON)
2b. [#68](https://github.com/skepsik/utlas-ts/issues/68)  ToolRunResult + compose block (опционально после 2)
3. [#38](https://github.com/skepsik/utlas-ts/issues/38)  geocode_place, composite
4. [#66](https://github.com/skepsik/utlas-ts/issues/66)  prompt policy
```

Этап 2 — «покажи 50/40» без `ToolRunResult` и без compose block.

---

## ToolRunResult (общий контракт runner)

**Work:** [#68](https://github.com/skepsik/utlas-ts/issues/68). До merge — [#67](https://github.com/skepsik/utlas-ts/issues/67) с **простым JSON** tool result в loop.

Каждый runner возвращает **единый envelope** — не ad-hoc JSON на tool:

```ts
type ToolRunResult = {
  ok: boolean;
  error?: string;
  /** Сериализуется в loop inject (этот turn). */
  result: unknown;
  /** Опционально: создать compose block между turn'ами. */
  block?: {
    kind: string;
    initialTtl: number;
    query: unknown;
  };
};
```

| Поле | Смысл |
|------|--------|
| `result` | ответ в **tool loop** (следующий LLM call того же turn) |
| `block` | кэш в `compose_blocks` + hydrate в prompt ([compose-blocks](../envelope/compose-blocks.md)) |
| `initialTtl` | из args tool (`initialTtl?`) или **default в registry** для этого tool |

Продление / revoke — по-прежнему top-level `blockTtl` в answer, не в runner.

### Args tool (общие optional)

```ts
// на уровне registry policy, не у каждого tool обязательно
type ToolArgsCommon = {
  initialTtl?: number; // clamp MAX_TTL; omit → default tool или без block
};
```

`search_messages`: `ttlTurns` в query → `block.initialTtl` (уже в [message-search](./message-search.md)).

### `show_map_pin` и compose block

**Долгосрочно** pin живёт в **CHAT HISTORY** (`map_pin` utterance) — этого достаточно для «что отправили в чат».

**На этапе 2b ([#68](https://github.com/skepsik/utlas-ts/issues/68))** — опционально **тот же** `ToolRunResult.block` для прогона связки:

```text
kind: map_pin
query: { lat, lon, label, egressMessageId }
initialTtl: default (напр. 3) или из args
```

Hydrate → секция в prompt (структурированный «последний pin»), параллельно строка в CHAT HISTORY.

Потом block для map можно **отключить** в registry (`block: never`) — контракт остаётся, consumer один.

| Tool | `result` (loop) | `block` (между turn) |
|------|-----------------|----------------------|
| `show_map_pin` | `{ messageId, lat, lon, label }` | опционально v0, likely off later |
| `geocode_place` | `GeocodeResult` | нет |
| `search_messages` | hits summary | да (`message_search`) |

---

## Зачем

Три разных смысла у «карты» и «места» нельзя сводить к одному LLM-tool на каждую комбинацию (`show_on_map_text`, `show_on_map_coords`, …) — **комбинаторный взрыв**.

Нужно:

- мало **атомов** (`geocode_place`, `show_map_pin`, …);
- для модели — простая декларация цепочки **без галлюцинации lat/lon**;
- для backend — **совместимые контракты** между шагами (mapper на ребре registry);
- ясно, **где** живёт память: tool result в loop vs typed egress в `messages`.

---

## Сейчас vs цель

| Аспект | Сейчас (v0) | Цель |
|--------|-------------|------|
| `toolCalls` в wire | нет в zod ([#38](https://github.com/skepsik/utlas-ts/issues/38)) | atomic + `composite` |
| Цепочки | — | registry **edges** + validator pipeline |
| Pin persist | `MessagePayload` `type: map_pin`, PG `messages.type` ([#65](https://github.com/skepsik/utlas-ts/issues/65), [#126](https://github.com/skepsik/utlas-ts/issues/126)) | document, venue, … |
| CHAT HISTORY | `formatMessage` по `payload.type` | больше вариантов utterance |
| Transport gate | — | `show_map_pin` только при `supportsMapPin` |

---

## Два уровня: атом и composite

### Атомарные tools (instruments)

Каждый tool: `name`, args schema, runner в `tools/runners/`. Egress-tools (pin) вызывают **`OutboundPort.deliver`**, не grammY напрямую.

| Tool | Слой | Transport |
|------|------|-----------|
| `geocode_place` | данные → `Geocoder` | agnostic |
| `show_map_pin` | egress → `sendLocation` + persist | **только если transport умеет pin** |
| `search_messages` | данные + compose-block | agnostic (см. [message-search](./message-search.md)) |

`show_map_pin` — **отдельный instrument**, не поле в `GeocodeResult`.

### `composite` (meta-tool)

Один элемент в `toolCalls[]`. Модель задаёт **вход первого шага** и **упорядоченный список имён** атомов; args последующих шагов **не заполняет**.

```json
{
  "toolCalls": [{
    "name": "composite",
    "arguments": {
      "input": { "text": "Кремль", "mode": "point" },
      "steps": ["geocode_place", "show_map_pin"]
    }
  }]
}
```

Смысл для prompt (не wire): `composite(вход, geocode_place, show_map_pin)` — «найди место, затем отправь pin».

**Один раунд LLM** может содержать:

- только `composite`;
- только один атом (`geocode_place` или `show_map_pin`);
- позже — несколько независимых атомов в одном массиве (редко в v0).

---

## Registry: рёбра, не готовые сценарии

```text
tools/registry/
  definitions/   ToolDefinition per atom (visibility, result policy) — [#126](https://github.com/skepsik/utlas-ts/issues/126)
  tools.ts       Map lookup + execute
  types.ts       ToolRegistry, ToolExecutorContext
  // later: chains.ts — allowed edges: mapOutputToInput(from, to)
```

Ребро — пара `(from, to)` + **типизированный mapper**, не новое имя в prompt:

```text
geocode_place ──► show_map_pin
  GeocodeResult.places[0] → { lat, lon, label }
```

**Валидатор** `steps[]`:

- каждая пара `(steps[i], steps[i+1])` зарегистрирована;
- иначе executor error → tool result в loop (модель может ответить текстом).

Новая продуктовая цепочка = **новое ребро в коде**, не `composite_show_kremlin` в каталоге LLM.

---

## Стартовые кейсы (ручные композиты)

Разные **смыслы** — разные формы вызова. Не «одна точка входа с разными сигнатурами», а **разные паттерны** `toolCalls`.

### 1. «Покажи Кремль» — место по имени → карта

```json
{
  "toolCalls": [{
    "name": "composite",
    "arguments": {
      "input": { "text": "Кремль", "mode": "point" },
      "steps": ["geocode_place", "show_map_pin"]
    }
  }]
}
```

Executor: geocode → mapper → pin. Модель **не** видит и **не** указывает координаты.

### 2. «Покажи точку 50/40» — координаты → сразу pin

Geocoder не нужен.

```json
{
  "toolCalls": [{
    "name": "show_map_pin",
    "arguments": { "lat": 50, "lon": 40, "label": "50, 40" }
  }]
}
```

Координаты: из args модели (после разбора user text в USER MESSAGE) или enrichment later — **явные числа**, не из geocode.

### 3. «Где офис?» — только данные, без карты

```json
{
  "toolCalls": [{
    "name": "geocode_place",
    "arguments": { "text": "офис компании", "mode": "point" }
  }]
}
```

Дальше loop: tool result → модель → `shouldReply: true` + текст («ул. …»). **`show_map_pin` не вызывается.**

### Сводка

| User intent | Вызов | Pin в чат |
|-------------|--------|-----------|
| покажи \<место\> | `composite` → geocode → pin | да |
| покажи lat/lon | `show_map_pin` | да |
| где \<место\> | `geocode_place` | нет |

Policy в PG block `tools` ([#66](https://github.com/skepsik/utlas-ts/issues/66)) учит модель **какой паттерн** выбрать; backend не подменяет выбор модели жёстким auto-pin для всех geocode (см. § Rejected).

---

## Tool loop и executor

```text
LLM → toolCalls? (atomic | composite)
  → execute (sequential; composite = внутренний цикл по steps)
  → tool results → optional re-LLM (cap итераций)
  → declarative patches
  → deliver если shouldReply
```

**Composite внутри:**

```text
ctx := input
for step in steps:
  args := step == 0 ? ctx : mapPrevToArgs(prevOutput, step)
  prevOutput := run(step, args)
return prevOutput
```

Промежуточный шаг с tools: `shouldReply: false`, `text: ""` — пока loop не завершён.

**Parallel executor** — later; v0 только sequential ([tools index](./index.md)).

---

## Память: три слоя

| Что | Где | Когда видит модель |
|-----|-----|-------------------|
| Tool result (geocode, search hits в loop) | ephemeral, inject в **следующий** LLM call **того же turn** | в loop, не в CHAT HISTORY |
| Текстовый ответ бота | `messages.text`, `payload` пустой | CHAT HISTORY со следующего turn |
| Map pin (egress) | `messages` + **`MessagePayload`** (`map_pin`) | CHAT HISTORY со следующего turn |

### `MessagePayload` (domain, не transport)

Когда plain **`messages.text` / `MessageRef.body` недостаточно** — optional typed `payload` на ref. **Обычный текст:** PG `type` null, данные в `text`. **Non-text:** колонка **`type`** + `payload` jsonb (поля варианта **без** discriminant внутри). Storage **собирает** / **разбирает** domain ↔ PG.

v0 в коде — только pin; при новых видах utterance union расширяем (**discriminated union** по **`type`** в domain):

```ts
type MapPinPayload = {
  type: "map_pin";
  lat: number;
  lon: number;
  label: string;
  address?: string;
};

type MessagePayload = MapPinPayload;
// later: MessagePayload = MapPinPayload | VenuePayload | …
```

- **Transport** мапит `sendLocation` → egress `kind: map_pin` → persist с `payload.type` ([#65](https://github.com/skepsik/utlas-ts/issues/65), [#126](https://github.com/skepsik/utlas-ts/issues/126)).
- **PG:** колонка **`type`** (`NULL` = plain text) + **`payload`** jsonb (поля варианта **без** `type` внутри). Storage **собирает** domain `MessagePayload` на read, **разбирает** на write.
- **CHAT HISTORY** (`formatMessage`): явная ветка, не угадывание по эмодзи:

```text
[time] Bot (bot) [map pin]:
  label: Красная площадь, Москва
  coordinates: 55.75, 37.62
```

Модель понимает: **отправлена карта**, не произвольная строка.

### Geocode без pin

`GeocodeResult` **не** пишется в `messages` как отдельная реплика — только tool result в текущем turn. В следующем turn модель помнит место, если бот **написал текст** или пользователь ссылается на контекст.

### Pin без обязательного текста в том же turn

После `show_map_pin` pin уже в ленте (`map_pin`). Финальный `shouldReply: false` допустим. Текстовый комментарий — опционально в том же loop или на **следующем** user turn, когда pin уже в CHAT HISTORY.

**Auto follow-up turn** сразу после pin (второй `runTurn` без user message) — **не** v0 канон; см. § Rejected / Later.

### Search vs pin

[Compose blocks](../envelope/compose-blocks.md) — TTL-кэш **результатов tools** (`message_search`, опционально `map_pin` на этапе 2). Pin **также** в CHAT HISTORY как `map_pin` utterance — основной долгосрочный канал для «карта была отправлена».

---

## Transport gate

```text
availableTools =
  atomic registry
  ∩ transport.capabilities (supportsMapPin → show_map_pin + composite с pin в steps)
  ∩ per-turn policy
```

Без pin: `show_map_pin` omit; composite с `show_map_pin` в `steps` недоступен в prompt; degrade — geocode + текст.

---

## Wire (ориентир)

```ts
type ToolCall =
  | { name: string; arguments: Record<string, unknown> }
  | {
      name: "composite";
      arguments: {
        input: Record<string, unknown> | string;
        steps: string[];
      };
    };
```

`input` для v0 geocode: object `{ text, mode? }` или string → `{ text }`. Уточнение в zod при [#38](https://github.com/skepsik/utlas-ts/issues/38).

---

## Размещение

```text
tools/registry/       atoms + chain edges; ToolRunResult defaults
tools/runners/          geocode, map-pin, …
turn/                   tool loop, composite executor
transport/              show_map_pin runner → OutboundPort.deliver map_pin ([#65](https://github.com/skepsik/utlas-ts/issues/65), [#69](https://github.com/skepsik/utlas-ts/issues/69))
storage/compose-blocks/ ToolRunResult.block (optional)
llm/prompt/format       CHAT HISTORY по MessagePayload.type; hydrate blocks
storage/messages        payload jsonb + migration
```

---

## Rejected

### Именованный composite-tool на каждый сценарий

`show_on_map`, `show_coords_on_map`, … в каталоге LLM (**не делаем**): комбинаторный взрыв; вместо этого meta `composite` + edges в registry.

### Модель заполняет lat/lon для pin после geocode

В одном ответе `show_map_pin({ lat, lon })` «из головы» после `geocode_place` (**не делаем**): галлюцинации; coords только из mapper, явных args пользователя или ingress later.

### `$ref` / `$from` в args как основной UX для модели

`arguments: { "$from": 0, "pick": "places.0" }` (**не v0**): мощно для тестов, хуже для качества вызова; канон — `composite` для цепочек.

### Backend всегда pin после любого geocode

(**Не делаем**): кейс «где офис» — только данные + текст; pin только когда модель выбрала composite или `show_map_pin`.

### Жёсткий второй turn после каждого pin

Auto `runTurn` без user message (**не v0**): усложняет supersede; pin в typed history достаточен для следующего qualifying ingress.

### Синтетическая карта только как plain `text`

«📍 lat, lon» в `body` без `MessagePayload` `type: map_pin` (**не делаем** как канон): модель не отличает карту от болтовни; нужен typed payload.

### Native provider tool chains

См. [native-tool-calls](./native-tool-calls.md) — **Rejected**.

---

## Открытые вопросы

- Точная форма `input` в `composite` для не-geocode первого шага (search, …).
- Ошибка на шаге composite: abort всей цепочки vs partial tool result.
- Denormalized `text` для `map_pin` в PG (для старых readers / export).
- Парсинг «50/40» из user text: модель vs enrichment vs оба.
- `show_map_pin` + compose block: оставить default on/off в registry после этапа 2.

---

## Later

- Parallel executor + независимые атомы в одном `toolCalls[]`.
- `$ref` в args для отладки и внутренних тестов.
- Optional auto follow-up turn после egress (policy flag).
- Ingress user location → `reverse` + composite/pin.
- Больше рёбер: `search_messages` → … (только с зарегистрированным mapper).

---

## Out of scope

- MCP tools transport
- Cross-chat tool results
- Composite длиной >3 без отдельного design-review (v0 ориентир: 2–3 шага)
