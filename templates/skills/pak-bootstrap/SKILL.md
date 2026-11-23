---
name: pak-bootstrap
description: >-
  One-time onboarding and architecture audit skill. Invoke via /pak-bootstrap (or ask the agent
  to bootstrap PAK) when installing pak into an existing repository or after major architectural
  milestones to audit code vs. stale markdown docs, quarantine dead folders, and generate
  code-verified docs/domains/*.md dossiers and dependency-matrix.md.
---

# Project Awareness Bootstrap & Stale-Doc Audit (`pak-bootstrap`)

Follow these exact steps to initialize full architectural awareness with minimal token usage:

## Step 1 — Generate the Mechanical Atlas First (`0` LLM Tokens)
Run the polyglot indexer so 80% of the structural discovery happens locally in Python:
```bash
python3 scripts/pak/build_atlas.py
```
Read `docs/atlas/00_SYSTEM_MAP.md`, `docs/atlas/01_CODE_CAPABILITIES.md`, and `docs/atlas/02_DATA_CONTRACTS.md`.

## Step 2 — Audit Live Code vs. Stale Docs & Dead Prototype Artifacts
1. List all `.md` files and top-level directories in the repository.
2. Verify existing `.md` claims against actual build configs (`Makefile`, `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`), entrypoints, and active database migrations.
3. Identify any **dead / obsolete prototype directories or schema dumps** (e.g., unused build exports, superseded SQL dumps, old entrypoints with zero live imports):
   - Add them to `"quarantined_paths"` in `pak.config.json`.
   - Update or replace stale `.md` instructions so future AI sessions are never misled by outdated docs.
4. Configure `"codegen_pairs"` and `"checks"` (`enforce_uuid_v7`, `i18n_locales_dir`, `banned_patterns`) in `pak.config.json` to match the repository's real invariants.

## Step 3 — Create Concise, Code-Verified Domain Dossiers (`docs/domains/*.md`)
Group the application into 3–10 bounded domains. Read the core service/domain files in parallel batches and create `docs/domains/<domain>.md` (**strictly ≤160 lines each**):
- **1. End-to-End Workflows & State Machines**
- **2. Non-Obvious Invariants, Formulas & Thresholds**
- **3. Corner-Case & Trap Registry** (race conditions, auth/security nuances, caching, timezones, precision)
- **4. Cross-Domain Impact Checklist**

## Step 4 — Populate the Implicit Coupling Matrix & Verify
1. Update `.agents/skills/pak-impact/references/dependency-matrix.md` (and `.claude/skills/...` if mirrored without symlinks) with the project's real cross-module runtime side effects.
2. Re-run and verify everything passes cleanly:
   ```bash
   python3 scripts/pak/build_atlas.py && bash scripts/pak/verify_impact.sh
   ```
