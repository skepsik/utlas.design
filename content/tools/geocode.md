# Geocode

Контракт **Geocoder** и атомарные LLM tools `geocode_place` / `show_map_pin`. Потоки, `composite`, память — [composite](./composite.md).

**Work:** [#60](https://github.com/skepsik/utlas-ts/issues/60) ✅ (runner) · [#38](https://github.com/skepsik/utlas-ts/issues/38) (loop) · [#65](https://github.com/skepsik/utlas-ts/issues/65) (pin egress).

---

## Geocoder contract

`tools/runners/geocode/` — **наш формат**; vendor JSON только в адаптерах ([#60](https://github.com/skepsik/utlas-ts/issues/60)).

```ts
/** GeocodePlace — `@utlas/core/domain/model/geocode-place.ts` */
type GeocodePlace = {
  label: string;
  at: GeoPoint;
  address?: string;
  kind?: string;
};

/** GeoPoint — class; create / fromUnknown — единственная сборка coords */
```

Сборка: `createGeocodePlaceAt(label, at, options?)`. Vendor-адаптеры парсят wire → `GeoPoint.fromUnknown` или `GeoPoint.create`, затем `createGeocodePlaceAt`.

`PlacesPayload.places` — **тот же** `GeocodePlace[]` ([message-payload](../domain/message-payload.md)); отдельный тип не вводим.

```ts
GeocodeQuery =
  | { mode: "point"; text: string }
  | { mode: "search"; text: string; limit?: number }
  | { mode: "reverse"; lat: number; lon: number }

GeocodeSourceSlice = { vendor, status, places: GeocodePlace[]; error? }

GeocodeResult = {
  query: GeocodeQuery;
  mode: …;
  places: GeocodePlace[];
  sources?: GeocodeSourceSlice[];
}

Geocoder = { resolve(query: GeocodeQuery): Promise<GeocodeResult> }
```

- Один объект ответа снаружи.
- **Reverse** в контракте; ingress location — *Later*.
- Fallback / merge — *Later* (`geocode-combine.ts`).

---

## Runners layout

```text
tools/runners/geocode/
  types.ts, mock.ts, yandex.ts, google.ts, combine.ts, registry.ts
```

Vendor = адаптер → `GeocodeResult`. Прямой `fetch`, не MCP.

---

## LLM tools (атомы)

| Tool | Действие |
|------|----------|
| `geocode_place` | `Geocoder.resolve({ mode, text \| lat/lon })` — **только данные** |
| `show_map_pin` | `OutboundPort.deliver` map_pin + persist **`points`** — [message-payload](../domain/message-payload.md) ([#65](https://github.com/skepsik/utlas-ts/issues/65), [#69](https://github.com/skepsik/utlas-ts/issues/69)) |

`show_map_pin` в registry **только** если transport `supportsMapPin`.

### Паттерны вызова (не дублировать здесь)

| Смысл | Форма |
|-------|--------|
| покажи \<место\> | `composite(input, geocode_place, show_map_pin)` |
| покажи lat/lon | `show_map_pin` |
| где \<место\> | `geocode_place` → текст, без pin |

Детали, wire, память — [composite](./composite.md).

Координаты в ответе модели **не trust** — только tool output / mapper на ребре registry. Geocode → карта → persist **`places`**, не `points` с address — [message-payload](../domain/message-payload.md).

---

## Фазы

1. [#65](https://github.com/skepsik/utlas-ts/issues/65) — `OutboundPort.deliver` map_pin + persist  
2. [#67](https://github.com/skepsik/utlas-ts/issues/67) — `show_map_pin` + minimal loop  
2b. [#68](https://github.com/skepsik/utlas-ts/issues/68) — `ToolRunResult` + compose block  
3. [#38](https://github.com/skepsik/utlas-ts/issues/38) — `geocode_place`, `composite`  
4. [#66](https://github.com/skepsik/utlas-ts/issues/66) — prompt  

См. [composite](./composite.md) § Этапы, § ToolRunResult.

---

## Later

- Ingress location → reverse
- `search_places` / multi-pin
- `geocode-combine`, per-tenant policy
- `sendVenue`, static map PNG

---

## Verify

```bash
npm run db:up && npm test && npm run check
```
