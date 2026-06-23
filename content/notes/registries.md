# Registries

> **Note** — чеклист на потом, не описание текущей структуры. Gate для кода: `.cursor/rules/ts-layout.mdc` § Registries.

## Контекст

В проекте несколько **registry** с разными контрактами:

| Registry | Ключ | Значение |
|----------|------|----------|
| `TransportRegistry` | `transport.type` | instance `Transport` |
| `ClientRegistry` | `type` | factory + `resolve()` |
| `EnrichmentRegistry` | `enricher.name` | `Enricher` |
| `StepRegistry` | `name` | `StepHandler` |

Общий `BaseRegistry` / `createTypeRegistry` **пока не выносим** — преждевременная абстракция ведёт к подгонке (client factory, enricher `name`, step handlers — разные паттерны).

---

## Правило

**При добавлении каждого нового registry** — явно пересмотреть:

1. Есть ли **2+ реализации с одинаковым контрактом** (register item by key, get, list)?
2. Если да — вынести **фабрику** (`createTypeRegistry<T extends { type: string }>()` или keyed variant), не класс-иерархию.
3. **Не подгонять** существующие registry задним числом.
4. `tools/runners/` — instruments оркестратора, не generic registry utils.

### Кандидат на будущую фабрику (не сейчас)

```ts
function createTypeRegistry<T extends { type: string }>() {
  // register / get / list
}
```

Подходит для transport-like plugin registry. Client (factory+resolve) и enrichment (`name`) — отдельные решения при пересмотре.
