# Geocode

Контракт geocoder и LLM tools для «где X» / «покажи на карте». Реализация — [#38](https://github.com/skepsik/utlas-ts/issues/38).

```
user message → turn (tool loop) → Geocoder → sendLocation egress
```

Tool loop: [index](./index.md). Answer envelope: [envelope](../envelope/index.md).

---

## Geocoder contract

`tools/runners/geocode-types.ts` — **наш формат**; vendor JSON только в адаптерах.

```ts
GeocodeQuery =
  | { mode: "point"; text: string }
  | { mode: "search"; text: string; limit?: number }
  | { mode: "reverse"; lat: number; lon: number }

GeocodePlace = { lat, lon, label, address?, kind?, … }

GeocodeSourceSlice = { vendor, status, places[], error? }  // merge/debug

GeocodeResult = {
  query: GeocodeQuery;
  mode: …;
  places: GeocodePlace[];   // 1 для point/reverse, N для search
  sources?: GeocodeSourceSlice[];
}

Geocoder = { resolve(query: GeocodeQuery): Promise<GeocodeResult> }
```

- Один объект ответа, не `GeocodeResult[]` снаружи.
- **Reverse** в контракте с первого дня; реализация — stub/mock, потом Yandex.
- Fallback / merge sources / per-tenant policy — *Later* (`geocode-combine.ts` + config).

---

## Runners layout

```text
tools/runners/
  geocode-types.ts
  mock-geocoder/          # детерминированные ответы, loop + tests
  yandex-geocoder/        # v0 real: point; reverse/search — stub → API
  google-geocoder/        # stub
  geocode-combine.ts      # Later
```

Vendor = адаптер vendor JSON → `GeocodeResult`. Прямой `fetch`, не MCP.

---

## LLM tools

| Tool | Действие |
|------|----------|
| `geocode_place` | `Geocoder.resolve({ mode: "point", text })` (и другие modes по args) |
| `send_map_pin` | egress `sendLocation` + persist fallback body в PG |

Цепочка v0: geocode → pin. Координаты в ответе модели **не** использовать.

---

## Фазы реализации (#38)

### A. Mock loop (блокер merge)

1. Контракт — все modes в types.
2. `MockGeocoder` — детерминированные `GeocodeResult`.
3. `toolCalls` в `LlmAnswer`; function calling на adapter.
4. Tool loop в `turn/run-turn.ts`.
5. Egress `sendLocation` + `saveBotReply`.
6. Tests: mock LLM + MockGeocoder + mock grammY — без HTTP/ключей.
7. Prompt: [tools index](./index.md) § Prompt.

### B. Yandex (после A)

- `yandex-geocoder`: `point` → API; `reverse` / `search` по одному.
- `YANDEX_GEOCODER_API_KEY` в env.
- Wiring: MockGeocoder → Yandex по config.

---

## Later

- Ingress location (pin без text) → reverse в turn
- `search_places` / multi-pin UX
- `geocode-combine` (fallback, merge sources)
- per-tenant geocoder policy
- `sendVenue`, static map PNG

---

## Verify (#38)

```bash
npm run db:up && npm test && npm run check
```

Manual (фаза B): «покажи на карте …» → pin в Telegram.
