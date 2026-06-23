# Parity roadmap

Живой чеклист TS runtime vs Python prod. Обновлять по мере закрытия work issues.

---

## Checklist

1. ~~Каркас: grammY, config, Postgres~~ ✅
2. ~~`transport/telegram/`~~ ✅
3. ~~`turn/` supersede (v0)~~ ✅
4. ~~`domain/` + literal thread + RecentMessages~~ ✅
5. ~~Envelope + prompt loader~~ ✅
6. ~~LLM Router ([#22](https://github.com/skepsik/utlas-ts/issues/22))~~ ✅
7. ~~Layout: `clients/` + `tools/` (sync, runners)~~ ✅
8. ~~Monorepo: `apps/runtime`, per-app `test/` ([#53](https://github.com/skepsik/utlas-ts/issues/53))~~ ✅
9. Semantic thread selectors beyond reply-chain — later — [domain](./domain.md)
10. Turn pipeline / start-stop — [turn-pipeline](./turn-pipeline.md)
11. Tenancy / multi-bot — [tenancy](./tenancy.md)
12. Cutover + sqlite→pg import
13. Tools sync + orchestrator wiring
14. `retrieval/` envelope/budget — stub
15. LLM tools loop — [#38](https://github.com/skepsik/utlas-ts/issues/38)
