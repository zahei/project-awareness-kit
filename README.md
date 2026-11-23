# `pak` — Project Awareness Kit

**Keep AI coding agents aware of every existing function, cross-layer side effect, and subtle corner case as your codebase grows—while cutting token spend by 30–50%.**

`pak` (`project-awareness-kit`) is a zero-dependency, vendor-neutral architecture & memory layer that works seamlessly across **Google**, **Anthropic**, and **OpenAI** CLI & AI IDEs:

| Ecosystem | Supported Tools | What `pak` Configures Automatically |
| :--- | :--- | :--- |
| **Google** | **Antigravity (`agy` CLI & IDE)**, **Gemini CLI** | `AGENTS.md`, `GEMINI.md`, `.agents/skills/pak-*`, `.agents/hooks.json` (`Stop` gate) |
| **Anthropic** | **Claude Code (`claude` CLI & IDE)** | `CLAUDE.md`, `.claude/skills/pak-*`, `.claude/settings.json` (`hooks.Stop` gate) |
| **OpenAI & Open Standard** | **Codex CLI (`codex`)**, **Cursor**, **Windsurf** | `AGENTS.md`, `.agents/skills/pak-*/agents/openai.yaml`, `.git/hooks/pre-commit` |

---

## Why Projects Need `pak` as They Scale

As applications grow past a few thousand lines of code, AI agents hit four predictable failure modes:
1. **$O(N^2)$ Token Burn:** Every tool-call turn re-sends the entire conversation history. Without a fast symbol map, an agent spends 12–20 exploratory turns grepping and reading 800-line files—burning 1M+ input tokens on routine features.
2. **Duplicate Functions & Components:** Unaware of existing helpers, SQL queries, or UI primitives, agents write near-duplicate utilities in new files.
3. **Missed Cross-Layer Ripple Effects:** Changing a database column, RPC message, or state machine silently breaks background workers, caches, notifications, or locale catalogs.
4. **Lost Corner Cases & Stale Markdown Traps:** Stuffing everything into `AGENTS.md` hits token caps and dilutes model attention, while outdated prototype `.md` files actively mislead future sessions.

---

## How `pak` Solves This (With Zero Idle Token Tax)

```text
Always-On (<1 KB)          Progressive Context (On-Demand)        Zero-Token Local Enforcement
─────────────────          ───────────────────────────────        ────────────────────────────
AGENTS.md / CLAUDE.md ───► Skills (.agents/ & .claude/skills) ──► Stop & Git Hooks (0 LLM tokens!)
Lean routing markers       • pak-atlas     (reuse lookup)         • verify_impact.sh
(non-destructive merge)    • pak-impact    (blast radius)           - Quarantined dead-path guard
                           • pak-domains   (corner cases)           - Codegen sync (proto/sqlc/prisma)
                           • pak-bootstrap (1-time audit)           - Optional UUIDv7 & regex rules
                                    │                               - Optional multi-locale i18n parity
                                    ▼                               - Auto-refreshes docs/atlas/00..04
                           Living Repo Knowledge (Self-Evolving)    - Structural-evolution dossier gate
                           • docs/atlas/00..04_*.md (symbols, contracts & live reverse-dependent graph)
                           • docs/domains/*.md      (self-routing ≤160-line workflows & corner cases)
```

### Token Economics
- **Local Python/Bash Indexers (`build_atlas.py`, `blast_radius.sh`, `verify_impact.sh`):** **0 LLM tokens** (pure local CPU, `<0.5s`, Python 3 stdlib only).
- **Idle Prompt Overhead:** **~180 tokens/turn** (only the 2-line skill frontmatter descriptions load by default via progressive disclosure).
- **Silent `Stop` Hooks:** **0 LLM tokens when checks pass**—only wakes the agent up for 1 corrective turn when a real invariant, codegen target, locale file, or structural evolution (`docs/domains/*.md` / `dependency-matrix.md`) needs attention.
- **Self-Evolving Dependency Graph & Domain Routing:** `build_atlas.py` automatically extracts internal import & reverse-dependent graphs (`04_DEPENDENCY_GRAPH.md`) across Go, TS/JS, Python, and Rust on every turn, and auto-discovers any new `docs/domains/<domain>.md` via its `> **Paths:**` header—zero edits to `SKILL.md` or `AGENTS.md` required as new domains emerge.

---

## Quickstart & Installation

**Requirements:** Python 3.9+, Bash, Git *(zero `pip` or `npm` packages required)*.

### Option A: Install `pak` Globally on Your Machine (Recommended)

```bash
git clone https://github.com/zahei/project-awareness-kit.git ~/projects/project-awareness-kit
cd ~/projects/project-awareness-kit
./pak install-cli
```

Now from **any** new or existing project directory, simply run:

```bash
cd /path/to/your-project
pak init
```

### Option B: Direct One-Line / Interactive Injection Without Global Install

```bash
# Interactive wizard (prompts for AI ecosystems, greenfield vs existing, hooks, & guardrails):
bash /path/to/project-awareness-kit/install.sh /path/to/your-project

# Non-interactive CI / scripted install (all 3 ecosystems + AI & Git hooks):
./pak init /path/to/your-project --yes --agents all --stage existing --hooks both
```

---

## Interactive Installer Choices

Running `pak init` interactively lets you tailor the installation in 15 seconds:

1. **Target AI Ecosystems:** `all` *(Google + Anthropic + OpenAI)*, `google`, `anthropic`, `openai`, or custom combination.
2. **Project Stage:**
   - **`greenfield`** — Seeds `docs/domains/00-core-architecture.md` and auto-maintains `docs/atlas/*` from commit #1.
   - **`existing`** — Auto-detects your stack (`Go`, `TS/JS/React`, `Python`, `Rust`, `SQL`, `Protobuf`, `Prisma`, `GraphQL`), generates `docs/atlas/*` immediately, and installs the `pak-bootstrap` skill.
3. **Verification Gates:** `both` *(AI `Stop` hooks + Git `pre-commit`)*, `ai`, `git`, or `none`.
4. **Built-in Guardrails:** Optional **UUIDv7** enforcement and auto-detected **multi-locale i18n JSON parity**.

> **Safe Non-Destructive Merging:** `pak init` uses `<!-- PAK:START --> ... <!-- PAK:END -->` blocks in `AGENTS.md`/`CLAUDE.md`/`GEMINI.md` and deep-merges JSON keys into `.agents/hooks.json` and `.claude/settings.json`. It **never** overwrites your existing rules, MCP configs, or permissions.

---

## Onboarding an Existing Complex Project (`/pak-bootstrap`)

After running `pak init` on an existing repository, open `agy`, `claude`, or `codex` and run a one-time audit:

> `"Activate the pak-bootstrap skill to audit this codebase, quarantine dead docs/paths in pak.config.json, and write docs/domains/*.md dossiers."`

What `pak-bootstrap` does automatically:
1. Runs `scripts/pak/build_atlas.py` (`0` tokens) to map all live functions, types, tables, endpoints, and internal module dependencies (`04_DEPENDENCY_GRAPH.md`).
2. Cross-checks existing `.md` files against actual build files and migrations—fixing stale documentation and quarantining dead prototype folders in `pak.config.json`.
3. Writes concise (`≤160 lines`), self-routing `docs/domains/<domain>.md` dossiers capturing workflows, formulas, and corner cases.
4. Populates `.agents/skills/pak-impact/references/dependency-matrix.md` with implicit runtime couplings.

---

## How `pak` Evolves Automatically as Your Project Grows

You never have to manually edit `AGENTS.md` or `SKILL.md` files as your architecture expands. `pak` keeps project memory and blast-radius awareness synchronized automatically through three mechanisms:

### 1. Auto-Generated Dependency & Reverse-Dependent Graph (`04_DEPENDENCY_GRAPH.md`)
On every check/turn, `build_atlas.py` parses internal `import` / `use` statements across **Go**, **TypeScript/JavaScript/React**, **Python**, and **Rust** (`0` LLM tokens) to maintain `docs/atlas/04_DEPENDENCY_GRAPH.md`:
- **Outbound Imports:** `Package / Page -> Dependencies`
- **Reverse Dependents (`<-`):** Instant *"Who imports module/component `X`?"* blast-radius map before editing any shared code.

### 2. Self-Routing Domain Dossiers (`> **Paths:**` Metadata)
Each file in `docs/domains/*.md` declares the paths it owns at the top of the file:

```markdown
# Domain Dossier: Payments & Billing

> **Paths:** `internal/payments/|proto/billing\.proto|web/src/pages/Billing`
> **Summary:** Stripe webhook idempotency, invoice state machine, and retry rules.
```

Whenever a new domain file is added to `docs/domains/`, `build_atlas.py` automatically registers it in `docs/atlas/00_SYSTEM_MAP.md` and `pak trace` (`blast_radius.sh`) routes matching queries and files to it dynamically—zero skill or script edits required.

### 3. Mechanical Structural-Evolution Gate (`Stop` Hook)
Whenever an AI turn modifies **DB migrations / API schemas** (`.sql`, `.proto`, `.prisma`, `.graphql`), creates a **new source module/component**, or introduces a **new internal dependency edge** in `04_DEPENDENCY_GRAPH.md`—without updating any `docs/domains/*.md` dossier or `dependency-matrix.md`—`verify_impact.sh` blocks the `Stop` hook once (`agy` and `claude`) so the agent updates the affected domain dossier (or creates a new one) in the same commit.
- Loop-safe: Honors `continuationActive` (Antigravity) and `stop_hook_active` (Claude Code) so pure refactors never cause infinite loops.
- CI / CLI flags: Set `PAK_STRICT_DOCS=1` to enforce strict dossier updates in CI/CLI mode, or `PAK_ACK_NO_DOC_IMPACT=1` to acknowledge a pure structural refactor with no domain-workflow change.

---

## CLI Reference

```bash
pak init [dir]          # Interactive (or --yes) setup in target repository
pak install-cli         # Symlink `pak` into ~/.local/bin/pak
pak atlas [dir]         # Regenerate docs/atlas/00..04_*.md (<0.5s, 0 tokens)
pak trace <query> [dir] # Trace reusable symbols, reverse dependents, schemas & domain dossiers
pak check [dir]         # Run deterministic codegen, dependency-graph, regex, i18n & evolution checks
pak uninstall [dir]     # Cleanly remove pak blocks, skills, and scripts
```

---

## Customizing Project Rules (`pak.config.json`)

Every installed project gets a clean `pak.config.json` at its root (see [`examples/pak.config.fullstack.json`](./examples/pak.config.fullstack.json)):

- **`quarantined_paths`**: Obsolete folders or SQL dumps ignored by the Atlas and blocked from accidental edits.
- **`generated_paths`**: Directories skipped during symbol indexing (`dist`, `gen`, `sqlc`, `node_modules`).
- **`codegen_pairs`**: Source-to-generated regex pairs ensuring `proto`, `sqlc`, `prisma`, or `openapi` outputs are regenerated whenever contracts change.
- **`checks.enforce_uuid_v7`**: Blocks `uuid.New()` / `uuidv4()` / `crypto.randomUUID()` when `true`.
- **`checks.i18n_locales_dir`**: Verifies all `<locale>.json` files match `en.json` key-for-key in `<80ms`.
- **`checks.banned_patterns`**: Array of `{ "regex", "path_regex", "message" }` rules for custom architectural or design-system invariants (e.g., blocking raw unadjusted SQL table reads or off-palette Tailwind colors).

---

## Running the Self-Test Suite

```bash
bash tests/smoke_test.sh
```

## License

[MIT](./LICENSE)
