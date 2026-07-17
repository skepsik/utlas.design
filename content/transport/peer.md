# Transport — Peer (bot-peer)

> Протокол bot↔bot для независимых реализаций (не runtime utlas). Максимальный паритет с [Telegram Bot API — Getting updates](https://core.telegram.org/bots/api#getting-updates); отличия и отложенное — явно ниже.

Бот публикует HTTP-точку той же формы, что Bot API; другие боты в чате читают его egress, который Bot API им не доставляет.

См. также: [transport](./index.md), [telegram](./telegram.md). Рядом по проблеме, другой подход: [context-bus](../prompts/context-bus.md).

---

## Граница документа

| Внутри спеки (норматив) | Снаружи (не часть протокола) |
|-------------------------|------------------------------|
| HTTP API, discovery, семантика updates | Как consumer кладёт update в свою БД / LLM / turn |
| Совместимость publisher ↔ consumer | Внутренности конкретного бота; форма URL до `/bot{token}/` |

Реализация **должна** быть возможна по этому документу + [Bot API](https://core.telegram.org/bots/api) (`Update`, `Message`, Making requests). Где написано «как в TG» — норматив = текст Bot API, не пересказ.

---

## Назначение

1. Publisher после успешной отправки в Telegram кладёт соответствующий `Update` в peer-outbox.
2. Consumer находит base URL по маркеру `bot-peer:` и вызывает `getUpdates` (long poll).
3. `Update` обрабатывается **как update Telegram** (тот же JSON-смысл полей).

Общая БД между ботами не требуется. Протокол не заменяет Bot API для human↔bot.

**Идемпотентность и нативный Bot API:** publisher **не** может знать и **не** обязан гарантировать, что consumer не получит то же сообщение ещё и от Telegram (bot-to-bot в Bot API и т.п.). Дедуп — **забота consumer’а** (типично `(chat.id, message_id)`). Publisher MUST публиковать свой успешный egress в peer независимо от того, начал ли Telegram доставлять bot-сообщения нативно.

---

## Паритет с Telegram: сразу и Later

Правило: всё, что есть у Getting updates / Making requests / объекты Update & Message — **цель паритета**. Ниже — что обязательно в первой реализации (v0) и что можно отложить, не ломая контракт.

### v0 (сразу)

| Область | Норматив |
|---------|----------|
| Making requests | HTTPS, GET/POST, те же способы передачи параметров, envelope `ok` / `result` / `error_code` / `description` / `parameters` |
| Auth URL | `https://{host}/bot{token}/{METHOD_NAME}` — как [Authorizing your bot](https://core.telegram.org/bots/api#authorizing-your-bot). Префикс path **до** `/bot` — внутренняя забота publisher’а (версия, reverse-proxy и т.д.); в маркере отдаётся готовый base, с которым работает consumer |
| Trailing slash | Как у TG: между token и методом — `/` (`…/bot{token}/getUpdates`). В маркере URL SHOULD заканчиваться на `/` после token, чтобы `{url}getUpdates` совпадал с TG-формой |
| `getMe` | Как в Bot API |
| `getUpdates` | Параметры и семантика **как в TG**: `offset` (в т.ч. отрицательный), `limit` 1–100 default 100, `timeout` default 0, `allowed_updates` (remember last setting; empty list = default TG) |
| Retention outbox | Как в TG: updates **не дольше 24 часов** |
| `Update` | Поля как в TG; неизвестные — ignore. В v0 publisher наполняет только `message` |
| `Message` | Полный объект Bot API **для того, что публикуется**. В v0 в outbox только **текстовые** исходящие (`text` present). Не-текст в v0 не класть |
| Discovery | Маркер `bot-peer:` (ниже) |
| Ошибки | Таблица `error_code` ниже (паритет с принятой практикой клиентов TG) |

### Later (паритет, не блокирует v0)

| Область | Суть |
|---------|------|
| Webhook | `setWebhook`, `deleteWebhook`, `getWebhookInfo` — взаимное исключение с `getUpdates`, как в TG |
| `edited_message` | При edit своего сообщения в Telegram — update в outbox |
| Не-текст в outbox | location, photo, document, … — когда появится: MUST полный `Message` как у TG (не subset) |
| Прочие поля `Update` | по мере нужды egress; форма — как в Bot API |
| `secret_token` на webhook | как у TG, когда будет webhook |

---

## Отличия от Telegram Bot API (неотменяемые)

| | Telegram Bot API | bot-peer |
|--|------------------|----------|
| Host | `api.telegram.org` | Host из discovery-URL |
| Содержимое outbox | Входящие updates **на** бота | Только **исходящие** сообщения publisher’а, успешно принятые Telegram |
| Откуда base URL | BotFather / конфиг | Маркер `bot-peer:` в description профиля |

---

## Making requests

Как в Bot API ([Making requests](https://core.telegram.org/bots/api#making-requests), [Authorizing your bot](https://core.telegram.org/bots/api#authorizing-your-bot)):

- HTTPS (исключение: loopback для dev).
- GET и POST; query / `application/x-www-form-urlencoded` / `application/json`; UTF-8; имена методов case-insensitive.
- Ответ:

```ts
{ ok: true, result: unknown }
{ ok: false, error_code: number, description: string, parameters?: object }
```

Шаблон:

```text
https://{host}/bot{token}/{METHOD_NAME}
```

`{token}` — секрет peer API в той же позиции, что bot token у TG. Ротация = новый token (старый path перестаёт работать).

Token в публичном description **не должен** совпадать с Bot API token бота (утечка = полный контроль над ботом в Telegram). Peer token — отдельный секрет той же URL-схемы.

---

## Discovery

В тексте description профиля бота:

```text
bot-peer: <url>
```

- Префикс: литерал `bot-peer:` (lowercase).
- После `:` — необязательный пробел, затем абсолютный URL (`https://`, или `http://127.0.0.1` / `http://localhost` для dev).
- URL — base вида `https://{host}/…/bot{token}/` (trailing `/` после token — см. паритет выше), так что `{url}getUpdates` и `{url}getMe` валидны.
- Несколько маркеров — первый слева направо.

Пример:

```text
bot-peer: https://peer.example.com/bot123456:AAHdqTcvCH1vGWJxh1uTNIhW2OnBYzEbk/
```

Как consumer читает description через Telegram API — его забота; протокол фиксирует маркер и смысл URL.

---

## Update

Форма — [Update](https://core.telegram.org/bots/api#update):

- `update_id` обязателен; не более одного optional-поля контента в одном update.
- Неизвестные поля consumer MUST игнорировать.

### `update_id`

Как в TG: положительные целые, монотонно в рамках token. Confirm: `getUpdates` с `offset` **строго больше** этого `update_id`.

### v0: только `message`

| Поле | Publisher v0 |
|------|----------------|
| `message` | MUST для каждого успешного **текстового** egress в Telegram |
| Остальное | MUST NOT в v0 (зарезервировано под Later) |

### Message = сообщение участника

Бот — полноценный участник чата. `message` — обычный [Message](https://core.telegram.org/bots/api#message): как от человека, с `from.is_bot: true`, `from.id` = Telegram id publisher’а. Peer-полей на Message нет.

В v0:

| Поле | Требование |
|------|------------|
| `message_id` | Id, возвращённый Telegram при send |
| `date` | Как в TG Message |
| `chat` | `id` чата отправки (+ прочие поля Chat MAY) |
| `from` | User бота; `is_bot` MUST be `true` |
| `text` | MUST (v0 = только текст) |
| Прочие поля Message | MAY; SHOULD совпадать с тем, что видно в Telegram |

Когда Later добавит не-текст: в outbox MUST уходить **полный** Message того же вида, что у Bot API для этого send — не урезанный stub.

Publisher MUST NOT класть в outbox то, что Telegram не принял. Outbox — только egress этого publisher’а (не human, не чужие боты).

**Retention:** updates хранятся не дольше **24 часов** (как Bot API). После истечения не возвращаются; слишком старый `offset` → как у TG (пустая выдача из оставшейся очереди, без отдельного «кода устаревания», если TG так себя ведёт для клиентов).

---

## getUpdates

Как [getUpdates](https://core.telegram.org/bots/api#getupdates):

| Parameter | Type | Required | Семантика |
|-----------|------|----------|-----------|
| `offset` | Integer | Optional | Как в TG (confirm, отрицательный offset) |
| `limit` | Integer | Optional | 1–100, default 100 |
| `timeout` | Integer | Optional | Секунды; default 0; положительный — long poll |
| `allowed_updates` | Array of String | Optional | Как в TG (в т.ч. remember previous; empty list = default TG) |

Ответ: `ok: true`, `result: Update[]` (возможно `[]` после timeout).

1. Client MUST обновлять `offset` после ответа (note Bot API).
2. При активном webhook (Later) — `getUpdates` MUST NOT работать, как в TG.
3. Long poll: ждать до event или `timeout`, иначе `[]`.

---

## getMe

Без параметров. `result` — [User](https://core.telegram.org/bots/api#user) publisher’а (`is_bot: true`), смысл как Bot API `getMe`.

---

## error_code

Норматив для peer (задача реализации — соблюдать таблицу; не Open). Ориентир — коды, которые ждут клиенты Bot API:

| `error_code` | HTTP (типично) | Когда |
|--------------|----------------|--------|
| 400 | 400 | Невалидные параметры (`description` объясняет) |
| 401 | 401 | Неверный / отозванный token |
| 404 | 404 | Неизвестный метод |
| 429 | 429 | Rate limit; `parameters.retry_after` (секунды), как ResponseParameters |
| 500 | 500 | Внутренняя ошибка publisher’а |

`description` — человекочитаемая строка. Расширение набора кодов — только additive и в духе TG.

---

## Чеклист совместимости

**Publisher**

- `getMe`, `getUpdates` по контракту; retention ≤ 24h.
- Outbox: только свой успешный текстовый (v0) egress как `Update.message` с полным Message.
- Монотонные `update_id` per token.
- Маркер `bot-peer:` с рабочим base URL.

**Consumer**

- Парсит `bot-peer:`, long-poll `getUpdates`, растущий `offset`.
- Игнорирует неизвестные поля.
- Дедуп на своей стороне (peer и/или нативный TG) — не требует гарантий от publisher.
- Не требует ничего кроме этого протокола.

---

## Reference implementation

В экосистеме utlas — отдельный пакет (рабочее имя **`bot-peer`**): HTTP server/client + discovery parse + outbox; без turn/storage/grammY. Glue в каждом боте — снаружи пакета.

---

## Открытые вопросы

- **Discovery fallback:** если description чужого бота недоступен через Bot API — pin / обмен URL (формат URL тот же).
- **Параллельные `getUpdates`:** один inflight на token или несколько; поведение при гонке offset (у TG на практике обычно один клиент).
- **CORS:** нужны ли заголовки; расчёт — server-to-server.

---

## Out of scope

- MTProto / userbot
- Доставка human-сообщений мимо Telegram
- Семантика «когда боту отвечать» (product / qualifying)
- Shared store / compose-лента ([context-bus](../prompts/context-bus.md))
- Версионирование path до `/bot` (забота publisher’а при выборе URL для маркера)
