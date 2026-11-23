<!-- PAK:START -->
## Architecture, Reuse & Impact Awareness (`pak`)
- **Pre-Edit Lookup (Zero Duplicate Code & Zero Missed Side Effects)**: Before creating any new function/query/endpoint/component or modifying shared logic, activate the **`pak-atlas`**, **`pak-impact`**, and **`pak-domains`** skills:
  1. Run `bash scripts/pak/blast_radius.sh "<symbol_or_topic>"` (or inspect `docs/atlas/*`) to **reuse or extend existing helpers, queries, contracts, and UI primitives** instead of duplicating them.
  2. Read the matching domain dossier(s) in `docs/domains/*.md` and `.agents/skills/pak-impact/references/dependency-matrix.md` to respect all workflows, state machines, and corner cases.
  3. Treat **live code + active migrations + tests** as truth; whenever a change alters workflows, couplings, or corner cases, **update `docs/domains/<domain>.md` in the same commit** (and delete superseded notes so stale docs never accumulate).
  4. Verify before finishing: `bash scripts/pak/verify_impact.sh` (also enforced automatically on turn completion / pre-commit).
<!-- PAK:END -->
