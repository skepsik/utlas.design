# MessagePayload

Typed тело реплики, когда plain `MessageRef.body` / PG `messages.text` недостаточно. Живёт в **`MessageRef.payload?`** — discriminant **внутри** union, не на верхнем уровне ref ([utterance](../utterance.md) § Rejected).

Hub — [domain](./index.md). PG mapping — [storage-mapping](../storage-mapping.md) § MessageRef. Когда tool пишет в историю — [tools/composite](../tools/composite.md) § Память.

---

## Зачем

Ветка `MessagePayload` — это вид содержимого, который пользователь различает как разный и который persist обязан хранить отдельно. Не тулза, не операция транспорта, не событие, не вариант рендера одного и того же содержимого.

Presentation (карта / таблица / текст на wire) — **не** в payload; только факт в ленте разговора для CHAT HISTORY.

---

## Три слоя (не синонимы)

| Слой | Имя | Смысл |
|------|-----|--------|
| Instrument | `show_map_pin`, later … | глагол модели |
| Wire | `ConversationOutboundItem.kind: 'map_pin'` | transport: `sendLocation`, один bubble |
| Domain | `MessagePayload.type: 'point' \| 'route' \| 'area'` | факт в истории разговора |

Mapper v0: wire `map_pin` → domain `point` (один элемент в `points[]`). Tool name и wire kind **не** меняются при смене domain-типа ([#127](https://github.com/skepsik/utlas-ts/issues/127)).

---

## Типы (плоский union)

Геометрия в истории — **siblings** в union, без зонтика `LocationPayload`:

```ts
type GeoPoint = {
  lat: number;
  lon: number;
  label?: string;
  address?: string;
};

type PointPayload = { type: "point"; points: GeoPoint[] };   // порядок не важен
type RoutePayload = { type: "route"; points: GeoPoint[] };   // порядок важен
type AreaPayload = { type: "area"; ring: GeoPoint[] };

type MessagePayload = PointPayload | RoutePayload | AreaPayload;
type MessagePayloadType = MessagePayload["type"];
```

**v0 в коде:** только `point` (литерал `map_pin` до [#127](https://github.com/skepsik/utlas-ts/issues/127)); `route` / `area` — типы в union + format stub, без runner'ов.

Код: `packages/core/src/domain/model/message-payload.ts`.

---

## MessageRef

```ts
MessageRef {
  // … id, body, sender, …
  payload?: MessagePayload;
}
```

**Обычный текст:** `payload` отсутствует, PG `type` = `NULL`, данные в `text`.

**Typed:** колонка PG **`type`** + **`payload`** jsonb (поля варианта **без** discriminant внутри). Storage **собирает** domain на read, **разбирает** на write — `packages/core/src/storage/messages/persist.ts`.

---

## PG

| PG | Domain |
|----|--------|
| `messages.type` = `NULL` | plain text, `payload` нет |
| `messages.type` = `point` \| `route` \| `area` | соответствующая ветка union |
| `messages.payload` jsonb | поля варианта без `type` |

Пример jsonb для `point`:

```json
{ "points": [{ "label": "…", "lat": 55.75, "lon": 37.62 }] }
```

Миграция prod: `map_pin` → `point`, flat body → `{ points: [...] }` ([#127](https://github.com/skepsik/utlas-ts/issues/127)).

---

## CHAT HISTORY

`formatMessage` (`packages/core/src/llm/prompt/format.ts`) — явная ветка по `payload.type`, не угадывание по эмодзи:

```text
[time] Bot (bot) [point]:
  label: Красная площадь, Москва
  coordinates: 55.75, 37.62
```

Заголовки для stub: `[point]`, `[route]`, `[area]`.

---

## Не в scope этой страницы

- Utterance table / отдельные ref-типы — [utterance](../utterance.md)
- Egress rename `kind` → `form` — [#128](https://github.com/skepsik/utlas-ts/issues/128)
- Tool loop, compose blocks — [tools/composite](../tools/composite.md)
