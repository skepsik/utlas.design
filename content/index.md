# Utlas design

Единый канон design. Разборы — в чате; решения вносятся в `content/`.

**Репозиторий:** [skepsik/utlas-design](https://github.com/skepsik/utlas-design) · локально `utlas-ts/design/`

## Core

| Страница | Тема |
| -------- | ---- |
| [layout](./layout.md) | Monorepo, слои, clients/tools, imports |
| [domain](./domain.md) | MessageRef, SemanticThread, glossary, ports |
| [storage-mapping](./storage-mapping.md) | MessageRef ↔ Postgres |
| [parity-roadmap](./parity-roadmap.md) | Parity checklist (живой) |

## Topics

| Страница | Тема |
| -------- | ---- |
| [turn-pipeline](./turn-pipeline.md) | Turn start/stop, pipeline, should_reply |
| [transport](./transport.md) | Ingress, qualifying, egress |
| [turn-prompt](./turn-prompt.md) | Envelope, voice, composer |
| [tenancy](./tenancy.md) | Multi-bot, owner, RLS, secrets |
| [context-bus](./context-bus.md) | Shared context в обход bot→bot |
| [registries](./registries.md) | Политика registry |
| [llm-envelope](./llm-envelope.md) | toolCalls, declarative patches |
| [message-search](./message-search.md) | Search tool over PG archive |
| [journal](./journal.md) | Scratchpad / per-chat memory |
| [llm-execution-policy](./llm-execution-policy.md) | Per-step retry vs strategy |

## Work-only (не design pages)

Timezone ([#48](https://github.com/skepsik/utlas-ts/issues/48)), LLM tools ([#38](https://github.com/skepsik/utlas-ts/issues/38)) — в work issues до sign-off.

## Процесс

- Work-очередь — issues в [utlas-ts](https://github.com/skepsik/utlas-ts) + доска Utlas Roadmap.
- Канон design — **только** этот репозиторий; design issues не ведём.
- Отклонённые гипотезы — секция **Rejected** в конце страницы.
