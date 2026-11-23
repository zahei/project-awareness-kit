<!-- PAK:START -->
## Architecture, Reuse & Impact Awareness (`pak`)
- **Tiered Pre-Edit Rule (Autopilot & Low-Token):**
  - *Isolated 1-component layout, CSS, or copy tweak:* Skip pre-edit PAK reads and implement directly; `.git/hooks/pre-commit` / `Stop` hooks enforce `verify_impact.sh`.
  - *New helper/query/endpoint/component, shared logic, or cross-layer edit:* Run `bash scripts/pak/blast_radius.sh "<symbol_or_topic>"` once to query reusable symbols, reverse dependents, git co-changes, sibling consumers (`contracts.json`), and inline domain summaries (`docs/domains/*.md`). Read a full dossier or `.agents/skills/pak-impact/references/dependency-matrix.md` only when workflows or cross-module contracts need deeper inspection.
- **Living Docs & Targeted Tests:** Update the matching `docs/domains/<domain>.md` in the same commit only when workflows, state machines, schemas, contracts, or corner cases change. Use `python3 scripts/pak/affected_tests.py --run` for targeted tests; commit/stop hooks run `bash scripts/pak/verify_impact.sh` automatically.
<!-- PAK:END -->
