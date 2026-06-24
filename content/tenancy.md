Связано: utlas-ts#22 (LLM Router, `api_key_ref` → env), inbox utlas-bot#24 («TELEGRAM_BOT_TOKEN → tenant_id / база»).

---

## Контекст

- Движение к **SaaS / white-label**, не один бот на VPS.
- **Несколько bot token'ов** в одном процессе / одной PG — актуально **независимо** от полноценного multitenancy.
- Отдельные DB-инстансы per tenant — **не скоро**; изоляция — **row-level** `tenant_id` + app-layer (RLS позже).
- Секреты (LLM keys, bot tokens) — **цель: уйти с `.env` в PG**; детали — отдельный issue, здесь только место в модели.

---

## Три оси (не путать)

| Ось | Сущность | Сейчас | Целевое |
|-----|----------|--------|---------|
| **Bot** | Telegram (и др.) token, transport instance | 1 token из env | N bots, token в PG |
| **Tenant** | SaaS-клиент, billing/isolation | нет | `tenant_id` row-level |
| **Secrets** | API keys, bot tokens | env + `api_key_ref` → env name (#22) | PG secrets store |

**Inbox-модель:** N bot token → 1 tenant — норма (несколько ботов одного клиента).

---

## Ключевое: два бота в одном Telegram-чате

**Исключать нельзя** — в т.ч. **два бота разных tenant'ов** в одной группе. Это штатная ситуация, не edge case.

Следствие: **`chat_id` alone — не identity** для настроек и watermark. Identity участия бота в чате = **`(bot_id, chat_id)`** (плюс `transport_type` при нескольких transport).

---

## Сущности (v0 design)

### `tenants`

```
id (uuid PK), name, created_at, …
```

Один default tenant при миграции с prod single-bot.

### `bots`

```
id, tenant_id FK, transport_type, secret_id FK, label, enabled, …
```

- Один bot = один Telegram token (через secrets).
- **Source of truth для tenant** на уровне bot.

### `bot_chats` (замена текущего `chats` по смыслу)

```
PK (bot_id, chat_id)   — + transport_type если нужно
tenant_id (optional denorm от bots — для RLS/queries, invariant = bots.tenant_id)
bot_enabled, context_limit_override, context_reset_*, title?, chat_type?, …
```

- **Не** registry membership Telegram — строка по **upsert при первом апдейте** (как сейчас `chats`).
- Настройки и `/forget` watermark — **per bot per chat**.
- Два tenant'а, один `chat_id` → **две строки**, без коллизий.

### `messages` — общая лента чата

```
UNIQUE (transport_type, chat_id, message_id)
```

- **`bot_id` / `tenant_id` на строке message — не нужны.**
- Оба бота в группе видят **одни и те же** message rows (факт Telegram).
- Отправитель: уже есть `user_id`, `is_bot`.

### `llm_calls`

- Добавить **`bot_id`** (audit: какой инстанс).
- Опционально `tenant_id` denorm для отчётов / RLS.

### LLM routing (`llm_endpoints`, strategies, …)

- v0 platform-global (как #22).
- Later: `tenant_id nullable` — NULL = platform keys, non-NULL = per-tenant endpoints/strategies.
- `api_key_ref` → эволюция в FK на **secrets** (не env var name).

### `secrets` (design placeholder, реализация — отдельный issue)

```
id, tenant_id nullable, ciphertext, name?, created_at
```

- Env: только `DATABASE_URL`, `SECRETS_MASTER_KEY` (или KMS later).
- Bot token и LLM keys — через `secret_id`.

---

## RLS (PostgreSQL, когда понадобится)

Контекст на transaction: `SET LOCAL app.tenant_id = …`, опционально `app.bot_id`.

| Таблица | Политика |
|---------|----------|
| **`bot_chats`** | Прямая: `tenant_id = current_setting('app.tenant_id')` (или через join `bots`). |
| **`messages`** | **Косвенная:** `EXISTS (bot_chats ⋈ bots WHERE bots.tenant_id = $tenant AND bot_chats.chat_id = messages.chat_id)`. Tenant видит messages **только из чатов, где участвует его bot**. Shared-группа: оба tenant'а видят одни rows — корректно. |
| **`bots`** | `tenant_id = …` |
| **`llm_calls`** | через `bot_id` / `tenant_id` |

RLS — **страховка** поверх app-layer scoping; pooling → только `SET LOCAL` per transaction.

Приложение **всё равно** передаёт `bot_id` в storage/turn — RLS не заменяет boundary types.

---

## Runtime (один процесс, N bots)

```
main: load enabled bots → N transport instances
each instance: botId в closure → TurnRequest / ingress / getChatSettings(botId, chatId)
MessageReadPort: history по chat_id; watermark — из bot_chats для этого bot_id
```

---

## Миграция с текущей схемы

1. `tenants` + default row.
2. `bots` + default bot (текущий `TELEGRAM_BOT_TOKEN`).
3. `bot_chats` ← backfill из `chats` с `bot_id = default`.
4. PK/unique на `messages` — без изменения смысла (уже transport+chat+msg).
5. Постепенно: secrets, multi-bot startup, RLS.

Один бот в prod — поведение как сейчас.

---

## Design constraints для кода **до** реализации

Чтобы не переделывать дважды:

- [ ] Не расширять `chats` PK только `chat_id` новыми semantically-per-bot полями — следующий шаг = `bot_id` в ключ.
- [ ] Новые storage API для chat settings — сигнатуры с **`botId`** (или context object), даже если пока один default.
- [ ] Ingress / `TurnRequest` — закладывать **bot identity** в boundary (transport instance id).
- [ ] Не вводить `tenant_id` «везде» без `bot_id` — multi-bot ломает модель раньше tenant.
- [ ] LLM config: не хардкодить «один global tenant»; endpoints/strategies расширяемы до `tenant_id nullable`.

---

## Out of scope (этот design)

- [ ] Реализация tables / migration
- [ ] Admin UI tenants / bots
- [ ] RLS policies в PG
- [ ] Secrets encryption / rotation
- [ ] Per-tenant LLM strategy wiring
- [ ] Отдельные PG-инстансы per tenant
- [ ] Orchestrator / billing

---

## Ожидаемые follow-up issues (не сейчас)

1. **Secrets in PG** — store + resolve port, `api_key_ref` → `secret_id`
2. **Multi-bot** — `bots`, `bot_chats`, `bot_id` в turn/storage, N transports
3. **Tenant row-level** — `tenants`, scoping, default tenant migration
4. **RLS** — policies по таблицам выше

---

## Acceptance (design issue)

- [x] Модель согласована
- [ ] Follow-up issues созданы по мере приоритизации (не обязательно все сразу)
