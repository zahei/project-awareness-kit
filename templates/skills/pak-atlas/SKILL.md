---
name: pak-atlas
description: >-
  Zero-token anti-duplication lookup via docs/atlas/. Activate BEFORE creating any new helper
  function, class, interface, database query, API/RPC endpoint, or UI component so existing
  capabilities are reused or extended rather than duplicated.
---

# Codebase Atlas & Anti-Duplication Skill (`pak-atlas`)

Never write duplicate utilities, queries, endpoints, or UI components. This repository maintains a zero-token, auto-generated index of live symbols and contracts in `docs/atlas/`.

## Mandatory Pre-Creation Protocol

1. **Query Existing Capabilities First (`0` LLM tokens to execute):**
   ```bash
   bash scripts/pak/blast_radius.sh "<keyword_or_concept>"
   ```
   Or inspect the compact generated files directly:
   - `docs/atlas/00_SYSTEM_MAP.md` — Project topology, quarantined legacy paths, and domain list.
   - `docs/atlas/01_CODE_CAPABILITIES.md` — Exported functions, classes, interfaces, hooks, and components.
   - `docs/atlas/02_DATA_CONTRACTS.md` — SQL tables, migrations, typed queries, Protobuf/GraphQL/Prisma schemas.
   - `docs/atlas/03_UI_AND_ASSETS.md` — CSS design tokens, themes, and i18n locale summary.
   - `docs/atlas/04_DEPENDENCY_GRAPH.md` — Module dependency & reverse-dependent graph (`<-`).
   - `docs/atlas/05_COCHANGE_AND_CONTRACTS.md` — Event-bus pub/sub topics, microservice links & git co-changes.

2. **Reuse Before Inventing:**
   - If an existing helper, validator, formatter, repository query, or component covers 70%+ of what you need, **extend or parameterize it** instead of creating a parallel implementation.
   - Never read or copy patterns from paths listed under `quarantined_paths` in `pak.config.json`.

3. **Keep the Atlas Fresh:**
   ```bash
   python3 scripts/pak/build_atlas.py
   ```
