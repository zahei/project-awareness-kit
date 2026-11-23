---
name: pak-impact
description: >-
  Cross-layer blast-radius and ripple-effect analyzer. Activate BEFORE modifying any shared type,
  database migration/query, API/RPC contract, core service, background worker, or cross-module
  UI state to trace callers and implicit side effects.
---

# Cross-Layer Impact Analysis Skill (`pak-impact`)

Before editing shared code, schemas, or contracts, trace both **static callers** and **implicit runtime couplings** in a single batched turn.

## Step-by-Step Protocol (Token-Frugal)

1. **Run the Deterministic Blast-Radius Script (`0` LLM tokens to execute):**
   ```bash
   bash scripts/pak/blast_radius.sh "<SymbolOrTableOrEndpoint>"
   ```
   In the **same parallel tool turn**, read:
   - [dependency-matrix.md](./references/dependency-matrix.md) (implicit runtime, event, worker, cache, and UI couplings that static `grep` misses)
   - Any matching `docs/domains/*.md` dossier(s) surfaced by `blast_radius.sh`.

2. **Token Discipline:**
   - For standard tasks (1–8 files), run `blast_radius.sh` + read the relevant dossier directly in 1 turn—avoid spawning subagents for small/medium tasks to save system-prompt token overhead.
   - Reserve read-only research subagents strictly for wide refactors touching 20+ files.

3. **Pre-Completion Verification:**
   Run the deterministic gate alongside your targeted unit tests:
   ```bash
   bash scripts/pak/verify_impact.sh
   ```
