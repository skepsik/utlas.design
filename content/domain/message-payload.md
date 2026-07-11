# MessagePayload

Typed тело реплики, когда plain `MessageRef.body` / PG `messages.text` недостаточно. Живёт в **`MessageRef.payload?`** — discriminant **внутри** union, не на верхнем уровне ref ([utterance](../utterance.md) § Rejected).

Hub — [domain](./index.md). PG mapping — [storage-mapping](../storage-mapping.md) § MessageRef. Когда tool пишет в историю — [tools/composite](../tools/composite.md) § Память.

Имена **instruments** и **egress item** (transport) — отдельная ось от **`MessagePayload.type`**, но **литералы согласованы** (`points` / `places`) — [#130](https://github.com/skepsik/utlas-ts/issues/130); здесь только **domain payload**.

---

## Зачем

Ветка `MessagePayload` — это вид содержимого, который пользователь различает как разный и который persist обязан хранить отдельно. Не тулза, не операция транспорта, не событие, не вариант рендера одного и того же содержимого.

Presentation (N bubble на wire, карта vs таблица) — **не** в payload; только факт в ленте для CHAT HISTORY.

---

## Два вида на карте

| Вид | Откуда | Смысл |
|-----|--------|--------|
| **`points`** | координаты от модели/пользователя (источник не важен) | группа **точек** — чистая геометрия + подписи |
| **`places`** | `geocode_place` → [`GeocodePlace[]`](../tools/geocode.md#geocoder-contract) | группа **мест** — resolved entities (label, address, kind) |

`geocode_place` **не** превращает результат в `points`. Composite geocode → показ на карте пишет **`places`**, не coords с address на point.

---

## Кардинальность и группа

**Всегда массив** — даже одна точка: `points: [{ at, label? }]`.

Одна egress-операция → **один** payload → **одна неразрывная группа** на карте (независимо от клиента). N send на wire — presentation; в PG **одна** строка `messages`.

Вторая операция → второй payload, даже подряд по времени. Несколько сообщений **не** склеиваются в одну группу (в т.ч. через будущий `Utterance`).

`title?` — подпись **группы** в CHAT HISTORY; `label` на элементе — подпись **точки/места**.

---

## Типы (плоский union)

```ts
/** class — единственная точка сборки coords; WGS84, finite; map helpers toLatLon / toLonLat */
class GeoPoint {
  readonly lat: number;
  readonly lon: number;
  static create(lat: number, lon: number): GeoPoint;
  static fromUnknown(value: unknown): GeoPoint | undefined;
}

type LabeledPoint = { at: GeoPoint; label?: string };
// createLabeledPointAt(at, label?)

/** @see geocode.md — тот же тип в GeocodeResult и PlacesPayload */
type GeocodePlace = {
  label: string;
  at: GeoPoint;
  address?: string;
  kind?: string;
};
// createGeocodePlaceAt(label, at, options?)

type PointsPayload = { type: "points"; title?: string; points: LabeledPoint[] };
type PlacesPayload = { type: "places"; title?: string; places: GeocodePlace[] };

type MessagePayload = PointsPayload | PlacesPayload;
type PayloadType = MessagePayload["type"];
```

**Later:** `route`, `area` — отдельные ветки union (геометрия пути/полигона), не подвид `points`/`places`.

**Read boundary:** `createLabeledPointFromUnknown`, `createGeocodePlaceFromUnknown` — jsonb / wire → domain (без type guards наружу).

Код: `packages/core/src/domain/model/message-payload.ts`, `geo-point.ts`, `geocode-place.ts`.

---

## MessageRef

```ts
MessageRef {
  // … id, body, sender, …
  payload?: MessagePayload;
}
```

**Обычный текст:** `payload` отсутствует, PG `type` = `NULL`, данные в `text`.

**Typed:** PG **`type`** + **`payload`** jsonb (поля варианта **без** discriminant внутри). Storage assemble/split — `packages/core/src/storage/messages/persist.ts`.

---

## PG

| PG | Domain |
|----|--------|
| `messages.type` = `NULL` | plain text |
| `messages.type` = `points` \| `places` | соответствующая ветка union |
| `messages.payload` jsonb | `title?`, `points[]` или `places[]` без `type` |

Пример `points` (domain и jsonb совпадают — nested `at`):

```json
{
  "title": "Координаты",
  "points": [{
    "at": { "lat": 55.75, "lon": 37.62 },
    "label": "Красная площадь"
  }]
}
```

Пример `places` — **jsonb flat** lat/lon; domain поднимает в `GeocodePlace.at` при read:

```json
{
  "places": [{
    "label": "Красная площадь",
    "lat": 55.75,
    "lon": 37.62,
    "address": "Москва, …"
  }]
}
```

---

## CHAT HISTORY

`formatMessage` — ветка по `payload.type`:

```text
[time] Bot (bot) [points]:
  title: Координаты
  - label: …
    coordinates: 55.75, 37.62

[time] Bot (bot) [places]:
  - label: …
    address: …
    coordinates: 55.75, 37.62
```

---

## Rejected

### `locations` + внутренний discriminant на wire и в payload

Один item `{ kind: "locations", variant: "points" | "places", … }` (**не делаем**): расщепляет discriminant — wire variant ≠ domain `type`, ломается тождество wire ↔ domain и прямой mapper «что отправили = что persist». Две ветки union на domain; wire — отдельная ось transport, не umbrella `locations`.

### Address на `LabeledPoint`

(**не делаем**): address — поле **`GeocodePlace`**, не `LabeledPoint`. Geocode-path → `places`, не `points` с address.

### Отдельный domain-тип `Place`

(**не делаем**): второй тип-синоним `GeocodePlace`. Канон — один `GeocodePlace` с `at: GeoPoint` ([geocode](../tools/geocode.md)); geocoder, persist и `PlacesPayload` — тот же тип.

### Один элемент без массива

Синглтон `lat/lon` на payload вместо `points: [...]` (**не делаем**): кардинальность всегда «группа»; `length === 1` — частный случай.

---

## Не в scope

- Имена LLM tools / egress item literals — [composite](../tools/composite.md) § Именование
- `places` runner / composite persist на карту — [#38](https://github.com/skepsik/utlas-ts/issues/38)
- Utterance table — [utterance](../utterance.md)
- Tool loop — [tools/composite](../tools/composite.md)
