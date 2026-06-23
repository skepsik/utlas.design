# Utlas design

Единый канон design. Разборы — в чате; решения вносятся сюда.

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

## Процесс

- Work-очередь — issues в [utlas-ts](https://github.com/skepsik/utlas-ts) + доска Utlas Roadmap.
- Design issues **не** ведём; канон только здесь.
- Отклонённые гипотезы — секция **Rejected** в конце страницы.
