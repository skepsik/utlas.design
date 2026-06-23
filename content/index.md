# Utlas design

Единый канон design. Разборы — в чате; решения вносятся в `content/`.

**Репозиторий:** [utlas.design](https://github.com/skepsik/utlas.design) · локально `utlas-ts/design/`

## Core

| Страница | Тема |
| -------- | ---- |
| [layout](./layout.md) | Monorepo, слои, clients/tools, imports |
| [domain](./domain.md) | MessageRef, SemanticThread, glossary, ports |
| [storage-mapping](./storage-mapping.md) | MessageRef ↔ Postgres |
| [parity-roadmap](./parity-roadmap.md) | Parity checklist (живой) |

## Turn & transport

| Страница | Тема |
| -------- | ---- |
| [turn-pipeline](./turn-pipeline.md) | Turn start/stop, pipeline, should_reply |
| [transport](./transport.md) | Ingress, qualifying, egress |
| [turn-prompt](./turn-prompt.md) | Prompt composer, voice, envelope slots |
| [llm-execution-policy](./llm-execution-policy.md) | Per-step retry vs strategy |

## LLM answer envelope

| Страница | Тема |
| -------- | ---- |
| [envelope](./envelope/index.md) | `LlmAnswer`: фазы, схема, parse, turn apply |
| [journal](./envelope/journal.md) | Declarative: scratchpad per-chat |
| [compose-blocks](./envelope/compose-blocks.md) | Declarative: `blockTtl`, hydrate, TTL |

## Tools

| Страница | Тема |
| -------- | ---- |
| [tools](./tools/index.md) | Tool loop, registry, prompt |
| [geocode](./tools/geocode.md) | Geocoder contract, map pin |
| [message-search](./tools/message-search.md) | `search_messages` |

## Later

| Страница | Тема |
| -------- | ---- |
| [tenancy](./tenancy.md) | Multi-bot, owner, RLS, secrets |
| [context-bus](./context-bus.md) | Shared context в обход bot→bot |
| [registries](./registries.md) | Политика registry |

Timezone ([#48](https://github.com/skepsik/utlas-ts/issues/48)) — work issue до sign-off.

## Процесс

- Work-очередь — issues в [utlas-ts](https://github.com/skepsik/utlas-ts) + доска Utlas Roadmap.
- Канон design — **только** этот репозиторий.
- Отклонённые гипотезы — секция **Rejected** в конце страницы.
