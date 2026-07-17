# Transport — Peer

> Протокол bot↔bot для независимых реализаций (не runtime utlas). Паритет с Bot API Getting updates; незакрытое — в § Открытые вопросы.

Открытый overlay над Telegram: бот публикует HTTP-точку в духе [Telegram Bot API — Getting updates](https://core.telegram.org/bots/api#getting-updates); другие боты в том же чате читают его egress, который Bot API им не доставляет.

См. также: [transport](./index.md), [telegram](./telegram.md). Рядом по проблеме, другой подход: [context-bus](../prompts/context-bus.md).

---

## Граница документа

| Внутри спеки (норматив) | Снаружи (не часть протокола) |
|-------------------------|------------------------------|
| HTTP API, discovery, семантика updates | Как consumer кладёт update в свою БД / LLM / turn |
| Совместимость publisher ↔ consumer | Внутренности конкретного бота (utlas или чужой) |

Реализация **должна** быть возможна только по этому документу + [Bot API](https://core.telegram.org/bots/api) (объекты `Update` / `Message`). Всё не зафиксированное здесь — в § Открытые вопросы, не «подразумевается».

---

## Назначение

1. Publisher после успешной отправки сообщения в Telegram кладёт соответствующий update в свой peer-outbox.
2. Consumer обнаруживает peer URL бота и вызывает `getUpdates` (long poll).
3. Полученный `Update` обрабатывается **как update Telegram** (тот же JSON-смысл полей).

Протокол не заменяет Bot API для human↔bot и не требует общей БД между ботами.

---

## Отличия от Telegram Bot API

Где не сказано иное — поведение как у Bot API. Явные отличия:

| | Telegram Bot API | Peer v0 |
|--|------------------|---------|
| Host | `api.telegram.org` | Host publisher’а (из discovery) |
| Содержимое outbox | Входящие updates **на** бота | Только **исходящие** сообщения publisher’а, успешно ушедшие в Telegram |
| Откуда берётся base URL | BotFather / конфиг | Маркер в описании профиля бота (ниже) |
| Webhook | Есть | Не в v0 (см. Open) |

**Auth — как в Bot API**, не отдельная схема: token в path после литерала `bot`.

---

## Making requests

Как в Bot API ([Making requests](https://core.telegram.org/bots/api#making-requests) / [Authorizing your bot](https://core.telegram.org/bots/api#authorizing-your-bot)):

- Только **HTTPS** (исключение: `localhost` / loopback для разработки).
- Методы: **GET** и **POST**.
- Параметры: query string, `application/x-www-form-urlencoded`, `application/json` (как в TG).
- UTF-8; имена методов case-insensitive.
- Ответ — JSON:

```ts
// успех
{ ok: true, result: unknown }

// ошибка
{ ok: false, error_code: number, description: string, parameters?: object }
```

HTTP status: при `ok: false` — согласованный с `error_code` (как принято у клиентов TG: смотреть и body, и status). Невалидный / отозванный token → `401` и `ok: false`.

База запросов — **тот же шаблон**, что у Telegram:

```text
https://{host}/bot{token}/{METHOD_NAME}
```

Пример: `https://peer.example.com/bot123456:AA…/getUpdates`

- `{token}` — секрет peer API в той же позиции, что bot token у TG.
- Ротация: новый token → новый base URL (старый path перестаёт принимать запросы).
- Token в description **не обязан** совпадать с Bot API token бота; **не рекомендуется** совпадение, если URL публикуется в профиле (иначе утечка даёт полный контроль над ботом в Telegram). См. Open.

---

## Discovery

Расширение вне Bot API. Consumer находит peer base URL бота по тексту **описания профиля** (Bot API description / about).

### Маркер (норматив)

В тексте description MUST встречаться ровно в таком виде (одна строка или часть строки):

```text
utlas-peer: <url>
```

- Префикс: литерал `utlas-peer:` (регистр префикса — lowercase).
- После `:` — необязательный пробел, затем URL.
- URL MUST быть абсолютным `https://` (или `http://127.0.0.1` / `http://localhost` только для dev).
- URL MUST быть base в форме `https://{host}/bot{token}/` (trailing slash — см. Open), так что `{url}getUpdates` вызывает метод.
- Если маркеров несколько — брать **первый** слева направо.

Пример:

```text
utlas-peer: https://peer.example.com/bot123456:AAHdqTcvCH1vGWJxh1uTNIhW2OnBYzEbk/
```

Как именно consumer читает description через Telegram (какая метод/поле) — обязанность стороны consumer; протокол фиксирует только **формат маркера** и смысл URL.

---

## Update

Объект **той же формы**, что [Update](https://core.telegram.org/bots/api#update) в Bot API:

- Обязательное поле: `update_id` (Integer).
- Не более одного optional-поля контента в одном update (`message`, `edited_message`, …).
- Неизвестные поля consumer MUST игнорировать (forward compatibility).

### `update_id`

Как в TG: положительные целые, монотонно возрастают в рамках одного token. Update confirmed, когда consumer вызывает `getUpdates` с `offset` **строго больше** этого `update_id`.

### Содержимое в Peer v0

| Поле Update | v0 publisher |
|-------------|--------------|
| `message` | MUST: каждое успешно отправленное в Telegram сообщение бота (текст и др. виды, которые бот реально шлёт) |
| `edited_message` | MUST NOT в v0 (зарезервировано; см. Open) |
| Остальные поля Update | MUST NOT в v0 |

### Message = сообщение участника чата

Бот — **полноценный участник** чата. `message` MUST быть обычным объектом [Message](https://core.telegram.org/bots/api#message) Bot API — тем же смыслом, что сообщение человека, с `from.is_bot: true` (и `from.id` = Telegram id бота-publisher). Отдельных peer-полей на Message нет: consumer обрабатывает его как реплику участника.

Обязательный минимум полей в v0:

| Поле | Требование |
|------|------------|
| `message_id` | Тот же id, что вернул Telegram при send |
| `date` | Unix time отправки (как в TG Message) |
| `chat` | `id` (и прочие поля Chat — MAY) совпадает с чатом отправки |
| `from` | User бота; `is_bot` MUST be `true`; `id` = Telegram id этого бота |
| `text` / `caption` / media-поля | Как у реального исходящего Message в Telegram |

Дополнительные поля Message (entities, reply_to_message, …) MAY присутствовать и SHOULD совпадать с тем, что видно в Telegram для этого сообщения.

Publisher MUST NOT класть в outbox сообщение, которое **не** было успешно принято Telegram (нет wire `message_id`).

Outbox MUST NOT содержать сообщения людей и других ботов — только egress этого publisher’а.

---

## getUpdates

Метод: `getUpdates`. Семантика параметров — как в [Bot API getUpdates](https://core.telegram.org/bots/api#getupdates), если не сужено ниже.

| Parameter | Type | Required | Peer v0 |
|-----------|------|----------|---------|
| `offset` | Integer | Optional | Как в TG: первый `update_id` к возврату; confirm = вызов с `offset` > последнего полученного id. Отрицательный offset — как в TG (хвост очереди, предыдущие забываются) |
| `limit` | Integer | Optional | 1–100, default **100** |
| `timeout` | Integer | Optional | Секунды long poll; default **0** (short poll). Положительный — long poll |
| `allowed_updates` | Array of String | Optional | Как в TG: фильтр типов. В v0 осмысленно только `["message"]`. Пустой список / omit — см. Open |

**Ответ:** `ok: true`, `result` — Array of Update (может быть пустым после истечения `timeout`).

**Правила:**

1. Client MUST пересчитывать `offset` после каждого успешного ответа (как note в TG), чтобы не получать дубликаты.
2. Пока для token активен webhook — `getUpdates` MUST NOT работать (если webhook появится; в v0 webhook нет — см. Open).
3. Long poll: сервер MAY держать запрос до `timeout` секунд или до появления update; при отсутствии update → `result: []`.
4. Max `timeout` — см. Open (пока ориентир TG-практики: часто ≤ 50).

---

## getMe

Метод: `getMe`. Без параметров.

**Ответ:** `ok: true`, `result` — [User](https://core.telegram.org/bots/api#user) бота-publisher (`is_bot: true`), тот же смысл, что Bot API `getMe`.

Нужен, чтобы consumer проверил, что endpoint принадлежит ожидаемому боту (`id` / `username`).

---

## Ошибки (минимум)

| Ситуация | `error_code` (ориентир) | Notes |
|----------|-------------------------|--------|
| Неверный / отозванный token | 401 | Unauthorized |
| Невалидные параметры | 400 | Bad Request; `description` человекочитаемый |
| Метод не реализован / не найден | 404 | |
| Слишком много запросов | 429 | MAY; `parameters.retry_after` как в TG ResponseParameters |

Полная таблица кодов — см. Open.

---

## Версионирование

- Auth в path — как у Bot API: `/bot{token}/{METHOD_NAME}`.
- Ломающие изменения протокола → новый base URL в description (новый host и/или новый token). Как версионировать path (`/v0/bot…` vs только host) — см. Open.
- Additive changes в рамках совместимого контракта: новые optional поля Update/Message, уже разрешённые Bot API.
- Удаление/смена семантики существующих полей без смены base URL запрещены.

---

## Чеклист совместимости

**Publisher**

- Отдаёт `getMe`, `getUpdates` по контракту выше.
- Пишет в outbox только свой успешный Telegram egress как `Update.message`.
- Держит `update_id` монотонными per token.
- Публикует marker `utlas-peer:` с рабочим HTTPS URL.

**Consumer**

- Парсит marker, вызывает `getUpdates` с растущим `offset`.
- Игнорирует неизвестные поля.
- Дедупит по `(chat.id, message_id)` на своей стороне (повторная доставка возможна при сбое offset).
- Не требует от publisher ничего кроме этого протокола.

---

## Открытые вопросы

- **Trailing slash:** канон base URL — с `/` на конце или без; MUST ли оба `…/getUpdates` и `…getUpdates` работать.
- **Retention outbox:** как в TG (не дольше 24h) или иной срок; поведение при слишком старом `offset` (пустой result vs ошибка).
- **Max `timeout`:** точный потолок (например 50), отклонение больших значений (clamp vs 400).
- **`allowed_updates` default:** полный паритет с TG (remember last setting) или в v0 всегда только `message` при omit.
- **Отрицательный `offset`:** обязателен ли паритет с TG в первой реализации.
- **Webhook:** `setWebhook` / `deleteWebhook` / `getWebhookInfo` — когда и с каким паритетом к TG.
- **`edited_message`:** обязать publisher при edit в Telegram; срок появления в v0 vs v0.1.
- **Не-text egress:** location, photo, document — MUST полный Message как у TG или достаточно subset + Open на media.
- **Параллельные `getUpdates`:** один inflight на token (как часто делают клиенты TG) или несколько; что при гонке offset.
- **Таблица `error_code`:** зафиксировать полный список и соответствие HTTP status.
- **Discovery fallback:** если description чужого бота недоступен через Bot API — pin / обмен URL командой (формат URL тот же).
- **Имя маркера:** остаётся `utlas-peer` или нейтральное `tg-peer` / `bot-peer` для чужих экосистем.
- **CORS / не-bot клиенты:** нужны ли заголовки; протокол рассчитан на server-to-server.
- **Версия в path:** нужен ли префикс `/v0` перед `bot{token}`, или версия только через host / новый token.
- **Peer token vs Bot API token:** запретить совпадение (MUST NOT), если URL в публичном description, или только SHOULD NOT.
- **Подпись запросов:** HMAC / `secret_token` как у webhook TG — нужно ли поверх path-token.
- **Сосуществование с Bot API 10+ bot-to-bot:** когда Telegram сам начинает доставлять часть bot-сообщений — peer всё ещё MUST публиковать тот же egress (идемпотентность у consumer) или MAY omit.

---

## Out of scope

- MTProto / userbot
- Доставка human-сообщений мимо Telegram
- Семантика «когда боту отвечать» (qualifying / product policy)
- Shared store / единая лента для compose ([context-bus](../prompts/context-bus.md) — другой дизайн, не альтернатива внутри этого протокола)
