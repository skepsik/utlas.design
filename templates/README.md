# Wiki templates

Канон — `content/` (VitePress `srcDir`). Шаблоны — **каркас**, не целевой объём. `examples/` — черновики, **не канон**.

| Файл | Когда |
|------|--------|
| [template-page.md](./template-page.md) | Любая design-страница: поведение, wire, или оба |
| [template-attention.md](./template-attention.md) | Чеклист при изменении кода; не layout-канон |
| [translate.md](./translate.md) | EN → RU для prose (дополняешь сам) |

**Эталоны** по объёму, стилю и заголовкам §:

- [semantic-thread.md](../content/semantic-thread.md) — behavior + Open
- [llm-execution.md](../content/llm-execution.md) — Сейчас vs цель + PG/код
- [llm-jobs.md](../content/llm-jobs.md) — концепт + Rejected
- [turn-pipeline.md](../content/turn-pipeline.md) — длинная behavior-страница + YAML

Hub (`index.md`), spike (`prompts/context-bus.md`) — без отдельного шаблона; см. § Паттерны.

Связь с issues и sync после merge — `utlas-ts` `.cursor/rules/ops.mdc` § Wiki.

---

## Язык

**Prose — русский.** Полный EN wiki не используем (путаница в предлогах и временах).

**Не whitelist EN-слов** — наоборот: [translate.md](./translate.md) — список фраз, которые **переводим** заданным RU. Остальное: compound блоком или по-русски, если перевод адекватен.

### Слои

1. **Идентификаторы кода** — как в репо: `` `runTurn` ``, `` `turn.stop` ``, `` `omit` ``.
2. **EN compound** — несколько слов = один термин; **блоком**, не по словам: *failure-driven fallback*, *structured output*, *tool loop*, *full replace*.
3. **Переводимые выражения** — если есть в [translate.md](./translate.md), используй указанный RU.
4. **Остальное** — русский текст.

### Образец

> **Failure-driven fallback** — не у вызывающего кода, а в **cascade** router.

EN compound целиком; переводимые части по-русски; русский скелет (предлоги, «не …, а …»).

### Антипаттерны

- «Failure-driven fallback у call site» — русские предлоги + непереведённый хвост.
- **Не сокращать глаголы до тире**, если теряется смысл («оценивают каждую ноду», «выбирает комбинацию»).
- Одно предложение на § в шаблоне — **не** целевой объём страницы.
- История миграций, sign-off, «сверено с кодом» на wiki-страницах.

### Заголовки §

Смешанно; **не менять синонимы между страницами**:

| Заголовок | Смысл |
|-----------|--------|
| **Сейчас vs цель** | v0 в коде vs архитектурная цель (**не** work-issues) |
| **Цель** | ближайшая work; `[#N]` → issue utlas-ts |
| **Открытые вопросы** | design TBD; issue не обязателен |
| **Later** | согласованное направление, не ближайший scope |
| **Out of scope** | явный fence («не v1»); ≠ Rejected |
| **Rejected** | **не делаем:** + почему |
| **Инварианты (не менять без ADR)** | жёсткие правила; заголовок с «**не** менять» |

Остальные § — по предмету, обычно **русский** (Зачем, Термины, Типы, …). Термины **Wire**, **Types** — ok.

На отдельных страницах (напр. [layout.md](../content/layout.md)) legacy § **Канон** / **Сейчас** — допустимы; новые страницы предпочитают **Сейчас vs цель** + тело.

### Списки

**Без `- [ ]`.** VitePress не рендерит task list; смысл ≠ issue-tracker. Обычные маркированные списки (`- пункт`).

### Таблицы Wire

Enum: `omit`, `present`, `invalid` — не переводить.

### Решения «не Open»

Не заводить § «утверждено» / «не является Open» без нужды — решения **в тело ближайшего §** (1–2 предложения). Отдельная таблица — только для scanability; пометка «на момент текста».

---

## Lifecycle и ops

| templates / wiki | ops.mdc (смысл) |
|------------------|-----------------|
| **Сейчас vs цель** | **Сейчас** + архитектурная цель |
| **Цель** + `[#N]` | **Цель** (work) |
| **Открытые вопросы** | **Open** |
| **Later** | **Later** |
| **Rejected** | **Rejected** |
| тело / **Канон** § | **Канон** |

После close issue: пункт **Цель** → тело страницы / **Сейчас vs цель**; устаревшее убрать.

---

## Новая страница с нуля

1. Скопировать [template-page.md](./template-page.md), выкинуть лишние §.
2. Открыть **близкий эталон** из списка выше — **уровень детализации**, не длину шаблона.
3. Имена — **как в коде**; design-only — пометка «(цель)».
4. Wire-first → Типы → Wire; behavior-first → Зачем → механика.
5. **Сейчас vs цель** — если есть разрыв код/архитектура; **Цель** — если есть work.
6. Prose по § Язык; спорные EN → [translate.md](./translate.md).

---

## template-page: каркас

Один файл для behavior + wire. **Не все § обязательны.**

Wire-first — Типы → Wire → …; behavior-first — Зачем → механика → …

---

## Паттерны без шаблона

| Паттерн | Пример |
|---------|--------|
| **Hub** | `content/index.md` |
| **Glossary** | `domain.md` |
| **Mapping** | `storage-mapping.md` |
| **Spike** | `prompts/context-bus.md` — blockquote «spike, не канон» |

---

## Attention

[template-attention.md](./template-attention.md) — чеклист при правке. § русские (`Контекст`, `Чеклист`, `Не делать`). Тот же язык prose.

---

## Ссылки из `templates/`

На канон: `../content/…`
