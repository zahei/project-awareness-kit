<!-- PAK:START -->
## Architecture, Reuse & Impact Awareness (`pak`)
- **Pre-Edit Lookup (Zero Duplicate Code & Zero Missed Side Effects)**: Before creating any new function/query/endpoint/component or modifying shared logic, activate the **`pak-atlas`**, **`pak-impact`**, and **`pak-domains`** skills:
  1. Run `bash scripts/pak/blast_radius.sh "<symbol_or_topic>"` to query the incremental SQLite/FTS5 symbol index, reverse-dependent graph (`04_DEPENDENCY_GRAPH.md`), git co-change partners (`05_COCHANGE_AND_CONTRACTS.md`), and linked microservice consumers (`contracts.json`)—always **reuse or extend existing helpers** instead of duplicating them.
  2. Read the matching self-routing dossier(s) in `docs/domains/*.md` and `.agents/skills/pak-impact/references/dependency-matrix.md` to respect all workflows, state machines, and corner cases.
  3. Treat **live code + active migrations + tests** as truth; whenever a change alters workflows, contracts, couplings, or corner cases, **update `docs/domains/<domain>.md` in the same commit** (and delete superseded notes so stale docs never accumulate).
  4. Run fast graph-targeted tests (`python3 scripts/pak/affected_tests.py --run`) and verify all gates (`bash scripts/pak/verify_impact.sh`).
<!-- PAK:END -->
