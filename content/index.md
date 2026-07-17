# Utlas design

Единый канон design. Разборы — в чате; решения вносятся в `content/`.

**Репозиторий:** [utlas.design](https://github.com/skepsik/utlas.design) · локально `utlas-ts/design/`

## Core

| Страница | Тема |
| -------- | ---- |
| [layout](./layout.md) | Monorepo, слои, clients/tools, imports |
| [domain](./domain/) | MessageRef, SemanticThread, glossary, ports |
| [message-payload](./domain/message-payload.md) | Typed payload: `points`, `places` |
| [semantic-thread](./semantic-thread.md) | SemanticThread: Selector → Heuristic → Builder |
| [storage-mapping](./storage-mapping.md) | MessageRef ↔ Postgres |

## Turn

| Страница | Тема |
| -------- | ---- |
| [turn-pipeline](./turn-pipeline.md) | Turn start/stop, pipeline, shouldReply |
| [turn-prompt](./turn-prompt.md) | Prompt composer, PG blocks, envelope |
| [Атомарный turn](./turn/Атомарный%20turn.md) | **(концепт)** turn = один inference; тезисы |
| [atomic-turn-open](./turn/atomic-turn-open.md) | **(концепт)** разобранное и открытое |
| [llm-jobs](./llm-jobs.md) | **(концепт)** answer vs inference jobs, profile + strategy |
| [llm-execution](./llm-execution.md) | Strategy (есть) + execution policy per step (пока нет) |

## Transport

| Страница | Тема |
| -------- | ---- |
| [transport](./transport/) | Ingress, qualifying, egress, ports |
| [telegram](./transport/telegram.md) | Telegram v0: identity, handlers, wire |
| [peer](./transport/peer.md) | Протокол bot↔bot, паритет TG getUpdates |

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
| [composite](./tools/composite.md) | Цепочки, `composite`, память tool loop |
| [native tool calls](./tools/native-tool-calls.md) | Rejected: native tools API, multi-message wire |
| [geocode](./tools/geocode.md) | Geocoder contract, map pin |
| [message-search](./tools/message-search.md) | `search_messages` |

## Prompts

| Страница | Тема |
| -------- | ---- |
| [questions-neutral](./prompts/questions-neutral.md) | Нейтральный слой ответов (v0), оси A/B/C |
| [context-bus](./prompts/context-bus.md) | Shared store для multi-bot (spike); ≠ [peer](./transport/peer.md) |

## Structure (later)

| Страница | Тема |
| -------- | ---- |
| [tenancy](./tenancy.md) | Multi-bot, owner, RLS, secrets |

## Attention

Чеклисты и spikes — [attention/](./attention/index.md).
