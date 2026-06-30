# Layout

Monorepo split — [#53](https://github.com/skepsik/utlas-ts/issues/53). Агентский gate (imports, boundaries): `.cursor/rules/ts-layout.mdc`.

---

## Канон

| Тема | Решение |
|------|---------|
| Репозиторий | **npm workspaces monorepo** в `utlas-ts`: **`packages/core`** (`@utlas/core`) + **`apps/runtime`** (`@utlas/runtime`); позже `apps/tma`, … |
| **Transport** | Ingress / qualifying / egress → **`MessageRef`** — [transport](./transport/) |
| **Clients** | Wire-level (HTTP, SSH, …): auth + протокол; **`ClientRegistry`**; multi-instance per-tenant |
| **Tools** | **`sync/`** vendor ↔ backend; **`runners/`** instruments для turn/orchestrator |
| **`storage/`** | PG-only (Drizzle) |
| **Orchestrator** | YAML per owner; system scenario |
| **Turn** | скобка конкурентности; v0 supersede in code — [turn-pipeline](./turn-pipeline.md) |
| **LLM** | Router + flat cascade из PG |

### Monorepo — `packages/core` + `apps/runtime`

Root репо: workspaces, drizzle, CI, docker — **не** product `src/`.

| Package | npm | Содержимое |
| ------- | --- | ---------- |
| **`packages/core`** | `@utlas/core` | `domain/`, `storage/`, `llm/` (router, adapters, prompt composer, answer), `utils/` |
| **`apps/runtime`** | `@utlas/runtime` | `transport/`, `turn/`, `clients/`, `tools/`, `orchestrator/`, `enrichment/`, `retrieval/`, runtime-only `llm/` (resolvers, wiring), `main.ts` |

**Imports:** runtime → `@utlas/core/*`; core **не** импортирует runtime / grammY / transport.

**Тесты:** `packages/core/test/` — domain, storage, llm; `apps/runtime/test/` — transport, turn, integration.

**Алиасы:** в runtime `@/*` → `apps/runtime/src/*`; cross-package — `@utlas/core/domain/*`, `@utlas/core/storage/*`, `@utlas/core/llm/*`.

```text
utlas-ts/
  packages/core/
    src/
      domain/           MessageRef, SemanticThread, ports, services
      storage/          Postgres, selectors, watermark
      llm/              router, adapters, prompt/, answer, policy
      utils/
    test/

  apps/runtime/
    src/
      transport/        telegram/, …
      turn/
      clients/          wire + ClientRegistry
      tools/
        sync/             vendor ↔ backend
        runners/          git, python, …
      orchestrator/
      enrichment/
      retrieval/
      llm/                resolvers, config (transport/turn hooks)
      main.ts             composition root
    test/
```

| Слой | Смысл |
|------|--------|
| **`clients/`** | Низкоуровневый доступ к внешнему API/протоколу. Без mapping в PG, без sync-сценариев. Credentials через `ClientRegistry`. |
| **`tools/sync/`** | Бизнес-связь vendor ↔ **наш backend** (webhooks, pull/push, mapping). Резолвит wire client через `ClientRegistry`; **своего registry нет**. |
| **`tools/runners/`** | Одноразовые instruments (git, python, geocoder — work [#38](https://github.com/skepsik/utlas-ts/issues/38)). |

**Imports:** `packages/core/domain/` не импортирует transport, clients, tools, SDK/ORM. `apps/runtime` тянет core через `@utlas/core/*`.

**Registries:** разные контракты; при новом registry — [attention/registries](./attention/registries.md).

---

## Слои и контракты

| Слой | Сущности / порты | Каталог |
|------|------------------|---------|
| **Domain** | `MessageRef`, `SemanticThread`, `RecentMessages`, `MessageReadPort` | `packages/core/src/domain/` — [domain](./domain.md) |
| **Turn** | `TurnRequest`, `runTurn`, supersede — **скобка конкурентности** | `apps/runtime/src/turn/` — [turn-pipeline](./turn-pipeline.md) |
| **Transport** | ingress, qualifying, **`OutboundPort`** | `apps/runtime/src/transport/` — [transport](./transport/) |
| **Clients** | wire + auth; `ClientRegistry` | `apps/runtime/src/clients/` |
| **Tools** | `sync/` (vendor↔backend), `runners/` (instruments) | `apps/runtime/src/tools/` |
| **Storage** | PG rows, selectors, watermark | `packages/core/src/storage/` — [storage-mapping](./storage-mapping.md) |
| **LLM** | router, adapters, prompt composer, answer | `packages/core/src/llm/`; runtime resolvers — `apps/runtime/src/llm/` |
| **Tenancy** | owner, bot binding, secrets | [tenancy](./tenancy.md) — later |
