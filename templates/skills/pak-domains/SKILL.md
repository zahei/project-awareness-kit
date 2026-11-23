---
name: pak-domains
description: >-
  On-demand deep memory for project workflows, state machines, invariants, and corner cases in
  docs/domains/*.md. Activate whenever reading, debugging, or modifying domain logic, and update
  the matching dossier in the same commit whenever behavior or edge cases change.
---

# Domain Context & Corner-Case Memory Skill (`pak-domains`)

Detailed workflows, exact formulas, state transitions, and subtle edge cases live in `docs/domains/*.md` (kept concise at ≤160 lines per file so loading one costs ~1,000 tokens instead of reading thousands of lines of raw source).

## 1. On-Demand Read Rule
- Inspect `docs/atlas/00_SYSTEM_MAP.md` (or run `bash scripts/pak/blast_radius.sh <topic>`) and read **only** the `docs/domains/<domain>.md` file(s) relevant to the current task.
- Treat **live source code + passing tests + active migrations** as ground truth if an older comment ever conflicts with code, and immediately fix the doc!

## 2. Co-Located Memory Update & Anti-Junk Rule
Whenever your code change:
- Adds or modifies a workflow, state machine, threshold, caching rule, or cross-module coupling, OR
- Fixes a subtle corner case / race condition / regression,

**update `docs/domains/<domain>.md` (and `dependency-matrix.md` if cross-module coupling changed) in the SAME commit:**
- Keep entries dense and code-verified (≤160 lines per dossier; do not copy function signatures already indexed in `docs/atlas/`).
- **Delete superseded documentation immediately** so stale "junk docs" never accumulate.
