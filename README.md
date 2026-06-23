# utlas-design

Канонический design для Utlas (TS runtime и смежное). Markdown в `content/`.

Локальная копия живёт **внутри** `utlas-ts/design/` (отдельный git, родительский репо в `gitignore`).

## Bootstrap (новый клон utlas-ts)

```bash
cd utlas-ts
git clone git@github.com:skepsik/utlas.design.git design
```

## Работа с контентом

```bash
cd design
git pull
# правки content/*.md
git status && git diff
git commit -m "…"
git push
```

## VitePress (локально)

```bash
cd design
npm install
npm run docs:dev      # http://localhost:5173/utlas/wiki/
npm run docs:build
npm run docs:preview  # http://localhost:4173/utlas/wiki/
```

## Deploy (VPS)

Push в `master` → GitHub Actions (`.github/workflows/deploy-wiki.yml`) собирает статику и кладёт на VPS.

**Secrets** в репозитории `utlas.design` (те же, что у utlas-ts deploy):

| Secret | Назначение |
|--------|------------|
| `VPS_HOST` | IP/hostname VPS |
| `VPS_USER` | SSH user (deploy) |
| `VPS_SSH_KEY` | private key |
| `VPS_SSH_PORT` | SSH port |
| `VPS_WIKI_PATH` | опционально; default `$HOME/utlas-wiki/www` |

**Разовая настройка nginx на VPS** (бот/wg/xray не трогаем):

```bash
bash scripts/setup-vps-wiki-nginx.sh
```

URL (только WireGuard, hub VPS): `http://10.243.63.1/utlas/wiki/`

С публичного IP wiki **не слушает** — nginx bind на `10.243.63.1:80` (+ `127.0.0.1` для локальных проверок).

Миграция с GitHub design issues — 2026-06 (контент в `content/`).
