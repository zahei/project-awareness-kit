---
name: pak-impact
description: >-
  Cross-layer and cross-microservice blast-radius analyzer. Activate BEFORE modifying any shared
  type, database migration/query, API/Protobuf/event-bus contract, core service, worker, or UI
  state to trace reverse dependents, git co-changes, and sibling service consumers.
---

# Cross-Layer & Cross-Service Impact Skill (`pak-impact`)

Before editing shared code, schemas, or service contracts, trace **SQLite symbols**, **reverse dependents**, **git co-change partners**, and **federated microservice consumers** in a single batched turn.

## Step-by-Step Protocol (Sub-Second, Token-Frugal)

1. **Run the Deterministic Blast-Radius Trace (`0` LLM tokens, `<100ms`):**
   ```bash
   bash scripts/pak/blast_radius.sh "<SymbolOrEndpointOrEventTopic>"
   ```
   In the **same parallel tool turn**, read:
   - [dependency-matrix.md](./references/dependency-matrix.md) (implicit runtime, worker, cache, and cross-service rules)
   - Any matching `docs/domains/*.md` dossier(s) surfaced at the bottom of `blast_radius.sh`.

2. **Run Only Affected Unit Tests (`1–3s` instead of full CI suites):**
   Instead of running slow full-repository test suites on every edit, compute and run only the graph-impacted tests:
   ```bash
   python3 scripts/pak/affected_tests.py --run
   ```

3. **Verify Invariants, Contracts & Evolution Gate:**
   ```bash
   bash scripts/pak/verify_impact.sh
   ```
