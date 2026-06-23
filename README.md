# utlas-design

Канонический design для Utlas (TS runtime и смежное). Markdown в `content/`.

Локальная копия живёт **внутри** `utlas-ts/design/` (отдельный git, родительский репо в `gitignore`).

## Bootstrap (новый клон utlas-ts)

```bash
cd utlas-ts
git clone git@github.com:skepsik/utlas-design.git design
```

## Работа

```bash
cd design
git pull
# правки content/*.md
git status && git diff
git commit -m "…"
git push
```

Веб-морда (VitePress + Vercel) — позже; пока источник истины — эти файлы.
