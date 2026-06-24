# Utlas design

Единый канон design. Разборы — в чате; решения вносятся в `content/`.

**Репозиторий:** [utlas.design](https://github.com/skepsik/utlas.design) · локально `utlas-ts/design/`

## Core

| Страница | Тема |
| -------- | ---- |
| [layout](./layout.md) | Monorepo, слои, clients/tools, imports |
| [domain](./domain.md) | MessageRef, SemanticThread, glossary, ports |
| [semantic-thread](./semantic-thread.md) | SemanticThread: Selector → Heuristic → Builder |
| [storage-mapping](./storage-mapping.md) | MessageRef ↔ Postgres |

## Turn & transport

| Страница | Тема |
| -------- | ---- |
| [turn-pipeline](./turn-pipeline.md) | Turn start/stop, pipeline, shouldReply |
| [transport](./transport.md) | Ingress, qualifying, egress |
| [turn-prompt](./turn-prompt.md) | Prompt composer, PG blocks, envelope |
| [llm-jobs](./llm-jobs.md) | **(концепт)** answer vs inference jobs, profile + strategy |
| [llm-execution](./llm-execution.md) | Strategy (есть) + execution policy per step (пока нет) |

## LLM answer envelope

| Страница | Тема |
| -------- | ---- |
| [envelope](./envelope/index.md) | `LlmAnswer`: фазы, схема, parse, turn apply |
| [declarative snapshots](./envelope/declarative-snapshots.md) | Журнал declarative-снимков (`kind`, watermark) |
| [scratchpad](./envelope/scratchpad.md) | Вид снимка: per-chat рабочий остаток модели |
| [compose-blocks](./envelope/compose-blocks.md) | Declarative: `blockTtl`, hydrate, TTL |
| [conversation-settings](./envelope/conversation-settings.md) | Declare-patch: per-chat settings (`timezone`, …) |

## Tools

| Страница | Тема |
| -------- | ---- |
| [tools](./tools/index.md) | Tool loop, registry, prompt |
| [geocode](./tools/geocode.md) | Geocoder contract, map pin |
| [message-search](./tools/message-search.md) | `search_messages` |

## Structure (later)

| Страница | Тема |
| -------- | ---- |
| [tenancy](./tenancy.md) | Multi-bot, owner, RLS, secrets |

## Attention

Чеклисты и spikes — [attention/](./attention/index.md).
