---
name: pak-domains
description: >-
  On-demand deep memory for project workflows, state machines, invariants, and corner cases in
  docs/domains/*.md. Activate whenever reading, debugging, or modifying domain logic, and update
  the matching dossier in the same commit whenever behavior, domains, or edge cases evolve.
---

# Domain Context & Self-Evolving Memory Skill (`pak-domains`)

Detailed workflows, exact formulas, state transitions, and subtle edge cases live in `docs/domains/*.md` (kept concise at ≤160 lines per file so loading one costs ~1,000 tokens instead of reading thousands of lines of raw source).

## 1. Dynamic Self-Routing Discovery
- Every dossier in `docs/domains/*.md` declares its owned path regex (`> **Paths:** ...`) and summary (`> **Summary:** ...`) at the top of the file.
- `scripts/pak/build_atlas.py` automatically indexes all `docs/domains/*.md` files into `docs/atlas/00_SYSTEM_MAP.md`, and `scripts/pak/blast_radius.sh` dynamically routes matched files to the right dossier(s).
- Treat **live source code + passing tests + active migrations** as ground truth if an older comment ever conflicts with code, and fix the doc immediately.

## 2. Mandatory Evolution & New-Domain Rule
*(Enforced automatically on structural/dependency evolution by `scripts/pak/verify_impact.sh`)*

1. **Existing Domain Evolves:** Whenever a change modifies a workflow, state machine, threshold, caching rule, schema/migration, API contract, or corner case, **update `docs/domains/<domain>.md` (and `dependency-matrix.md` if cross-module coupling changed) in the SAME commit**. Delete superseded notes immediately so stale docs never accumulate.
2. **New Domain / Subsystem Added:** Whenever a brand-new bounded context or subsystem is introduced, create `docs/domains/<new-domain>.md` starting with:
   ```markdown
   # Domain Dossier: <Title>

   > **Paths:** `<regex_matching_owned_files_or_dirs>`
   > **Summary:** <1-sentence summary of workflows and invariants>
   ```
   `build_atlas.py` and `blast_radius.sh` will automatically discover and route to it with zero edits to `SKILL.md` or `AGENTS.md`.
