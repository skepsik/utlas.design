# Layout

**Статус:** sign-off 2026-06 — monorepo `apps/runtime`, taxonomy **clients/tools**, layout сверен с кодом.

Агентский gate (imports, boundaries): `.cursor/rules/ts-layout.mdc`.

---

## Зафиксировано

| Тема | Решение |
|------|---------|
| Репозиторий | **npm workspaces monorepo** в `utlas-ts` (`apps/runtime`, позже `packages/*`, `apps/tma`); sibling к [`ai-bot`](https://github.com/skepsik/ai-bot) |
| **Transport** | Ingress / qualifying / egress → **`MessageRef`** — [transport](./transport.md) |
| **Clients** | Wire-level (HTTP, SSH, …): auth + протокол; **`ClientRegistry`**; multi-instance per-tenant |
| **Tools** | **`sync/`** vendor ↔ backend; **`runners/`** instruments для turn/orchestrator |
| **`storage/`** | PG-only (Drizzle) |
| **Orchestrator** | YAML per owner; system scenario |
| **Turn** | скобка конкурентности; v0 supersede in code — [turn-pipeline](./turn-pipeline.md) |
| **LLM** | Router + flat cascade из PG |

### Monorepo — `apps/runtime`

Пути слоёв — относительно `apps/runtime/src/`. Тесты runtime — `apps/runtime/test/` (per-app convention).

`domain/` · `transport/` · `clients/` · `tools/` · `orchestrator/` · `turn/` · `enrichment/` · `storage/` · `retrieval/` · `llm/` · `utils/` · `env.ts` · `config.ts` · `types.ts` · `main.ts`

```text
apps/runtime/
  src/
    clients/            wire clients + ClientRegistry (jira/, github/, …)
    tools/
      sync/             vendor ↔ backend — jira/, obsidian/, google/, iiko/ (без registry)
      runners/          git/, python/, … — instruments для turn/orchestrator
    transport/          telegram/, jira-comments/ (later)
    …
  test/                 unit/integration runtime
```

Root репо: workspaces, drizzle, CI — не product `src/`. Алиас внутри runtime: `@/*` → `src/*`.

**Убрано:** корневые `clients/`, `infra/` (→ `tools/sync/`, `tools/runners/git/`).

| Слой | Смысл |
|------|--------|
| **`clients/`** | Низкоуровневый доступ к внешнему API/протоколу. Без mapping в PG, без sync-сценариев. Credentials через `ClientRegistry`. |
| **`tools/sync/`** | Бизнес-связь vendor ↔ **наш backend** (webhooks, pull/push, mapping). Резолвит wire client через `ClientRegistry`; **своего registry нет**. |
| **`tools/runners/`** | Одноразовые instruments (git, python, geocoder — work [#38](https://github.com/skepsik/utlas-ts/issues/38)). |

**Imports:** `domain/` не импортирует `transport/`, `clients/`, `tools/`, SDK/ORM.

**Registries:** см. [registries](./registries.md) — `TransportRegistry`, `ClientRegistry`, `EnrichmentRegistry`, `StepRegistry`.

---

## Слои и контракты

| Слой | Сущности / порты | Каталог |
|------|------------------|---------|
| **Domain** | `MessageRef`, `SemanticThread`, `RecentMessages`, `MessageReadPort` | `domain/` — [domain](./domain.md) |
| **Turn** | `TurnRequest`, `runTurn`, supersede — **скобка конкурентности** | `turn/` — [turn-pipeline](./turn-pipeline.md) |
| **Transport** | ingress, qualifying, `ReplySender` | `transport/` — [transport](./transport.md) |
| **Clients** | wire + auth; `ClientRegistry` | `clients/` |
| **Tools** | `sync/` (vendor↔backend), `runners/` (instruments) | `tools/` |
| **Storage** | PG rows, selectors, watermark | `storage/` — [storage-mapping](./storage-mapping.md) |
| **Tenancy** | owner, bot binding, secrets | [tenancy](./tenancy.md) — later |
