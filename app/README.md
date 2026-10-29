# ⚠️ LEGACY — `app/` (single-region reference lab)

This directory is the **original single-region** EventBridge lab. It is kept as a
simple, self-contained demo and is driven by the non-`-prod` scripts
(`scripts/create.sh`, `test.sh`, `destroy.sh`).

**For anything production or multi-region, use the layered build instead:**
`bootstrap/` → `platform-primary/` → `platform-secondary/` → `platform-global/`
→ `application/` (see `docs/FOLDER_STRUCTURE.md` and
`docs/PRODUCTION_ARCHITECTURE.md`).

`app/` does NOT have the production capabilities added later — no multi-region,
global endpoint, cross-account sharing, schema registry, Pipes, prod Scheduler,
or Access Analyzer. Those live only in the `platform-*` roots + `application/` +
`modules/`.

Do not build new work here. If this confuses the handover, retire `app/` and its
non-`-prod` scripts entirely; the layered build fully supersedes it.
