# Implicit Cross-Domain Coupling & Ripple-Effect Matrix

> Maintained alongside code changes. Static `grep` catches direct imports, while this matrix records **implicit runtime, event-driven, cache, background-worker, and schema couplings**.

| If You Touch... | Hidden Upstream / Downstream Consumers You MUST Check |
| :--- | :--- |
| **Database Migrations / Schema** | 1. Regenerate typed query/ORM clients (`pak.config.json` -> `codegen_pairs`).<br>2. Check raw SQL queries, background workers, and seed/test fixtures. |
| **API / RPC Contracts** | 1. Regenerate server stubs and frontend clients.<br>2. Update API handlers, auth/rate-limit middleware, and integration mocks. |
| **Core Domain Models / State Machines** | 1. Check background jobs/schedulers, event subscribers, cache invalidation keys, and notification templates.<br>2. Update the matching `docs/domains/<domain>.md` dossier in the same commit. |
| **UI Components / User-Facing Strings** | 1. Reuse semantic design tokens from `docs/atlas/03_UI_AND_ASSETS.md`.<br>2. Sync all configured locale catalogs if `i18n_locales_dir` is enabled in `pak.config.json`. |
