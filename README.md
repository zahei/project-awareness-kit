# `pak` — Project Awareness Kit (`v2.3.0`)

**Sub-second architectural memory, anti-duplication indexing, cross-microservice contract safety, and blast-radius verification for AI coding agents—with zero background daemons, zero external dependencies, and 30–50% lower LLM token usage.**

`pak` (`project-awareness-kit`) bridges **Google**, **Anthropic**, and **OpenAI** CLI & IDE agents through a unified, self-evolving repository intelligence layer:

| AI Ecosystem | Supported CLI / IDEs | Native Files Configured by `pak init` |
| :--- | :--- | :--- |
| **Google** | **Antigravity (`agy` CLI & IDE)**, **Gemini CLI** | `AGENTS.md`, `GEMINI.md`, `.agents/skills/pak-*`, `.agents/hooks.json` (`Stop` gate) |
| **Anthropic** | **Claude Code (`claude` CLI & IDE)** | `CLAUDE.md`, `.claude/skills/pak-*`, `.claude/settings.json` (`hooks.Stop` gate) |
| **OpenAI & Standard** | **Codex CLI (`codex`)**, **Cursor**, **Windsurf** | `AGENTS.md`, `.agents/skills/pak-*/agents/openai.yaml`, `.git/hooks/pre-commit` |

---

## Table of Contents

1. [The Core Problem: Why AI Agents Break Complex Codebases](#1-the-core-problem-why-ai-agents-break-complex-codebases)
2. [Design Philosophy & Token / Latency Economics](#2-design-philosophy--token--latency-economics)
3. [How `pak` Works Under the Hood (Architecture & Logic)](#3-how-pak-works-under-the-hood-architecture--logic)
   - [Layer 1: Lean Constitution + Progressive-Disclosure Skills](#layer-1-lean-constitution--progressive-disclosure-skills)
   - [Layer 2: Incremental SQLite + FTS5 Symbol & Dependency Engine](#layer-2-incremental-sqlite--fts5-symbol--dependency-engine)
   - [Layer 3: Self-Routing Domain Dossiers (`docs/domains/*.md`)](#layer-3-self-routing-domain-dossiers-docsdomainsmd)
   - [Layer 4: Hidden Git Co-Change Mining (`git log` Probability)](#layer-4-hidden-git-co-change-mining-git-log-probability)
   - [Layer 5: Multi-Repo Microservice & Event-Bus Federation](#layer-5-multi-repo-microservice--event-bus-federation)
   - [Layer 6: Multi-Vendor `Stop` Gate, Wire-Breaking & Duplicate Guards](#layer-6-multi-vendor-stop-gate-wire-breaking--duplicate-guards)
   - [Layer 7: Graph-Driven Affected-Only Test Runner (`pak affected`)](#layer-7-graph-driven-affected-only-test-runner-pak-affected)
4. [Installation & Quickstart](#4-installation--quickstart)
5. [Onboarding Workflows: Greenfield vs. Existing Complex Codebases](#5-onboarding-workflows-greenfield-vs-existing-complex-codebases)
6. [Complete CLI Reference & Upgrading](#6-complete-cli-reference--upgrading)
7. [Configuration Reference (`pak.config.json` & Environment Flags)](#7-configuration-reference-pakconfigjson--environment-flags)
8. [Uninstalling `pak` (Project-Level & System-Wide)](#8-uninstalling-pak-project-level--system-wide)
9. [End-to-End Automated Test Suite](#9-end-to-end-automated-test-suite)

---

## 1. The Core Problem: Why AI Agents Break Complex Codebases

When an application scales past ~20k–500k+ lines of code—or splits across multiple microservices—standard AI agent setups break down in five predictable ways:

1. **$O(N^2)$ Exploratory Token Burn:** Every tool-call turn re-sends the entire conversation history to the model. Without a compact capability index, an agent spends 12–20 turns grepping and reading 800-line files just to understand existing signatures—burning 1M–2M+ input tokens on a medium feature.
2. **Silent Function & Component Duplication:** Unaware that `FormatAccountCurrency()` or `<NumericInput />` already exists in another package, the agent writes `RenderAccountCurrency()` from scratch.
3. **Missed Cross-Layer & Cross-Microservice Ripple Effects:** Editing a Protobuf message, REST route, SQL table, or Kafka/NATS/CustomEvent topic inside `billing-service` silently breaks downstream consumers in background workers, frontend tabs, or sibling microservice repos (`notification-worker`, `web-portal`).
4. **Forgotten Corner Cases & Stale Markdown Traps:** Stuffing all documentation into `AGENTS.md` hits token caps and dilutes attention ("lost in the middle"), while old prototype `.md` files and dead folders left in the repo actively trick agents into following obsolete patterns.
5. **Slow Verification Loops:** Heavy Spec-Driven frameworks add 6-stage LLM ceremonies before writing a single line of code, while running full test suites on every edit adds 10–30 minutes of waiting.

---

## 2. Design Philosophy & Token / Latency Economics

`pak` is engineered around four strict constraints:
- **Zero Background Daemons (`0 MB` idle RAM):** No resident LSP servers, Docker containers, or vector databases.
- **Zero External Dependencies:** Pure **Python 3 standard library** (`sqlite3` + `FTS5`, `re`, `json`, `subprocess`) + `bash` + `git`. Works offline on any Linux, macOS, or WSL machine.
- **Sub-Second Execution (`<300ms`):** Incremental SQLite indexing caches parsed AST/regex metadata by `(mtime_ns, size)` so warm runs on massive repos re-parse `0` unchanged files in `<25ms`.
- **Zero Idle LLM Token Tax:** Local scripts run on your CPU (`0` LLM tokens). Progressive-disclosure skills inject only ~180 tokens of YAML frontmatter until needed, and `Stop` hooks emit `allow` silently (`0` extra LLM turns) whenever checks pass.

```text
Always-On (<1 KB)            On-Demand Progressive Context             Sub-Second Local CPU Gates (<300ms)
─────────────────            ─────────────────────────────             ───────────────────────────────────
AGENTS.md / CLAUDE.md  ───►  Skills (.agents/ & .claude/skills)  ───►  verify_impact.sh (AGY / Claude / Git)
Non-destructive markers      • pak-atlas     (reuse before coding)     1. Quarantined dead-path guard
                             • pak-impact    (full blast radius)       2. Codegen freshness (proto/sqlc/prisma)
                             • pak-domains   (corner-case memory)      3. Wire-breaking Proto/SQL diff guard
                             • pak-bootstrap (1-time brownfield)       4. Mechanical duplicate-symbol detector
                                      │                                5. Multi-locale i18n key parity
                                      ▼                                6. Cross-microservice consumer warning
                             Incremental SQLite + Living Docs          7. Structural-evolution dossier gate
                             • .pak/index.sqlite  (FTS5 + graph)
                             • docs/atlas/00..05  (auto-generated)
                             • docs/atlas/contracts.json (federation)
                             • docs/domains/*.md  (self-routing specs)
```

---

## 3. How `pak` Works Under the Hood (Architecture & Logic)

### Layer 1: Lean Constitution + Progressive-Disclosure Skills
Instead of bloating `AGENTS.md` or `CLAUDE.md` with thousands of lines of architecture prose, `pak init` inserts a tiny ~15-line `<!-- PAK:START --> ... <!-- PAK:END -->` routing block (preserving all your existing rules). Detailed workflows live inside four skills (`pak-atlas`, `pak-impact`, `pak-domains`, `pak-bootstrap`) whose full instructions are loaded **only** when triggered.

### Layer 2: Incremental SQLite + FTS5 Symbol & Dependency Engine
`scripts/pak/build_atlas.py` maintains `.pak/index.sqlite` (automatically gitignored via `.pak/.gitignore`) and renders 6 human- and grep-friendly markdown/JSON files in `docs/atlas/`:
- **Incremental `(mtime_ns, size)` Cache:** On every run, `build_atlas.py` stats source files across **Go, TypeScript/JS/React, Python, Rust, SQL, Protobuf, Prisma, GraphQL, and CSS**. Only modified or newly added files are re-parsed; unchanged files are read straight from SQLite in milliseconds.
- **BM25 Full-Text Search (`symbols_fts`):** Uses SQLite's built-in `FTS5` engine so `pak trace <query>` ranks matching symbols, interfaces, SQL queries, and components instantaneously.
- **Reverse-Dependent Graph (`04_DEPENDENCY_GRAPH.md`):** Extracts internal `import` and `use` edges across Go packages, TS/JS modules (including `./`, `../`, and `@/` aliases), Python modules, and Rust crates—rendering both outbound imports (`A -> B`) and **Reverse Dependents (`B <- A, C, D`)** so the agent immediately sees every downstream caller before editing `B`.

### Layer 3: Self-Routing Domain Dossiers (`docs/domains/*.md`)
Static code indexes tell an agent *what functions exist*, but not *business invariants, state machines, or subtle corner cases*. Those live in concise (`≤160 lines` each) domain dossiers inside `docs/domains/*.md`.

Each dossier carries two header lines right below its title:

```markdown
# Domain Dossier: Payments & Invoicing

> **Paths:** `internal/payments/|proto/billing\.proto|web/src/pages/Billing`
> **Summary:** Stripe webhook idempotency, retry backoff, and currency rounding invariants.
```

**Zero Hardcoded Routing:** Whenever a new `docs/domains/<domain>.md` file is created, `build_atlas.py` automatically discovers it and registers it in `docs/atlas/00_SYSTEM_MAP.md`, and `pak trace` matches touched files against its `Paths` regex dynamically—you never have to edit `SKILL.md` or `AGENTS.md` as new domains are born.

### Layer 4: Hidden Git Co-Change Mining (`git log` Probability)
Static `import` analysis cannot see implicit couplings across languages or boundaries—such as a ClickHouse SQL table modified alongside a Python ingestion script and a TypeScript DTO, or two config files that must always change in lockstep.

`build_atlas.py` scans the last 250 commits in `git log` (filtering out >20-file bulk formatting commits, unit-test twins like `foo.go <-> foo_test.go`, and pairs already linked by direct static imports) and computes conditional probability:

$$P(B \text{ changes} \mid A \text{ changes}) = \frac{\text{commits}(A \cap B)}{\text{commits}(A)}$$

Pairs meeting `cochange_min_commits` (default `3`) and `cochange_min_confidence` (default `0.65`) are recorded in `docs/atlas/05_COCHANGE_AND_CONTRACTS.md` and `contracts.json`, surfacing automatically during `pak trace`!

### Layer 5: Multi-Repo Microservice & Event-Bus Federation
For distributed microservice architectures spread across multiple Git repositories:
1. In each repository, `build_atlas.py` extracts **HTTP/REST routes** (`provides` & `consumes`), **Protobuf RPCs**, **GraphQL/SQL schemas**, and **Event-Bus Pub/Sub topics** (`.Publish("invoice.paid")`, `.Subscribe("invoice.paid")`, `@EventPattern`, `CustomEvent`) into `docs/atlas/contracts.json`.
2. Link sibling repositories via `pak link ../web-portal ../notification-worker` (or `"linked_repos"` in `pak.config.json`).
3. Running `pak trace "invoice.paid"` inside `billing-service` immediately queries every linked repo's `contracts.json` and prints exact cross-repo consumers (`../web-portal/src/api/billingClient.ts:L5`).
4. Modifying a file that provides an endpoint/topic consumed by a linked repo triggers an automatic cross-microservice impact notice in `pak check` / `verify_impact.sh`.

### Layer 6: Multi-Vendor `Stop` Gate, Wire-Breaking & Duplicate Guards
`scripts/pak/verify_impact.sh` speaks **all three enforcement protocols** natively from a single script:
- **Google Antigravity (`--agy-hook`):** Emits `{"decision": "allow"}` or `{"decision": "continue", "reason": "..."}` (respecting `continuationActive` so it never loops infinitely).
- **Anthropic Claude Code (`--claude-hook`):** Emits `{}` or `{"decision": "block", "reason": "..."}` (respecting `stop_hook_active` loop guard).
- **OpenAI Codex CLI & Human Commits:** Runs via `.git/hooks/pre-commit` and `pak check`.

On every dirty coding turn, `verify_impact.sh` enforces:
1. **Quarantined Legacy Guard:** Blocks accidental edits to dead prototype directories/files listed in `quarantined_paths`.
2. **Codegen Sync:** Verifies `proto`, `sqlc`, or `prisma` generated outputs updated whenever source contracts changed.
3. **Wire-Breaking Contract & Migration Diff Guard:** Inspects `git diff HEAD` on `.proto` and SQL migration files—blocking deleted RPCs, removed/reassigned Protobuf field tag numbers without `reserved`, or destructive `DROP COLUMN` / `ALTER COLUMN TYPE` statements unless explicitly acknowledged.
4. **Mechanical Near-Duplicate Function Detector:** Normalizes newly added function names into canonical action stems (mapping synonyms like `fetch`/`load`/`retrieve` → `get`, `render`/`fmt` → `format`, `calc`/`calculate` → `compute`) and queries `.pak/index.sqlite`. Adding `RenderAccountCurrency()` when `FormatAccountCurrency()` already exists in another package triggers an immediate reuse prompt with the exact `file:line`!
5. **Multi-Locale i18n Key Parity:** Verifies all `<locale>.json` catalogs match `en.json` key-for-key in `<80ms`.
6. **Self-Evolving Architecture Gate:** If a turn modifies schemas/contracts, adds a new source module, or introduces a new dependency edge in `04_DEPENDENCY_GRAPH.md` without updating `docs/domains/*.md` or `dependency-matrix.md`, blocks the AI `Stop` hook once so domain docs evolve in the same commit.

### Layer 7: Graph-Driven Affected-Only Test Runner (`pak affected`)
To prevent 30-minute full-suite test bottlenecks on large projects, `pak affected` reads your `git diff`, walks **2 hops up the Reverse-Dependent Graph** in `.pak/index.sqlite`, and computes (or executes with `--run`) **only** the impacted Go packages, Vitest/Jest test files, or Pytest modules—verifying changes in **1–3 seconds**.

---

## 4. Installation & Quickstart

**Requirements:** Python 3.9+, Bash, Git *(zero `pip` or `npm` packages required)*.

### Option A: Global `pak` CLI Install (Recommended — Auto-Configures `zsh`, `bash` & `fish`)

**One-liner (macOS / Linux):**
```bash
curl -fsSL https://raw.githubusercontent.com/zahei/project-awareness-kit/main/install.sh | sh
```

**Or from a manual Git clone:**
```bash
git clone https://github.com/zahei/project-awareness-kit.git ~/projects/project-awareness-kit
cd ~/projects/project-awareness-kit
./pak install-cli
```
`pak install-cli` symlinks `~/.local/bin/pak` and **automatically detects your login shell** (`zsh`, `bash`, or `fish`), injecting `PATH` inside `# --- PAK:START ---` markers in `~/.zshrc`, `~/.bashrc`, or `~/.config/fish/config.fish` (creating `~/.zshrc` automatically on fresh macOS/Linux `zsh` setups if absent). Run `source ~/.zshrc && rehash` (or open a new terminal tab) to activate `pak` in an already-open shell.

Then inside **any** project repository:

```bash
cd /path/to/your-project
pak init
```

### Option B: Direct / Non-Interactive Project & CI Install

```bash
# Interactive wizard (prompts for AI ecosystems, greenfield vs existing, hooks, UUIDv7, i18n & linked repos):
pak init /path/to/your-project

# Non-interactive install configuring Google + Anthropic + OpenAI + sibling microservice links:
pak init /path/to/your-project --yes --agents all --stage existing --hooks both --link-repos "../auth-svc,../web-app"
```

---

## 5. Onboarding Workflows: Greenfield vs. Existing Complex Codebases

### Starting a Brand-New (Greenfield) Project
1. Run `pak init` and select **`greenfield`**.
2. Start building normally in `agy`, `claude`, or `codex`.
3. As new modules, migrations, and domains are created, `build_atlas.py` updates `docs/atlas/*` automatically and the `Stop` hook prompts your agent to create/update `docs/domains/<domain>.md` dossiers incrementally—so the project **never** loses context from Day 1 to 500k LOC.

### Onboarding an Existing Complex / Multi-Service Codebase
1. Run `pak init` in each repository (and link sibling services via `pak link ../other-service` if multi-repo).
2. Open `agy`, `claude`, or `codex` in the repository and send:
   > `"Activate the pak-bootstrap skill to audit this codebase, quarantine dead docs/paths in pak.config.json, and write self-routing docs/domains/*.md dossiers."`
3. Commit the generated `pak.config.json`, `docs/atlas/*`, `docs/domains/*.md`, and skill/hook files.

---

## 6. Complete CLI Reference & Upgrading

```bash
pak --version                    # Print installed global pak CLI version
pak init [dir]                   # Interactive (or --yes) installer for a new/existing repository
pak upgrade [dir...]             # From ANY folder: upgrades system pak CLI + ALL your pak projects!
pak status [dir]                 # From ANY folder: lists all managed projects (or detailed view inside a repo)
pak link <sibling_repo...>       # Link sibling microservice repos for cross-repo contract tracing
pak install-cli                  # Symlink ~/.local/bin/pak & inject PATH into zsh/bash/fish RC
pak atlas [dir]                  # Incrementally update .pak/index.sqlite & docs/atlas/00..05 (<50ms)
pak trace <query> [dir]          # Search FTS5 symbols, reverse dependents, co-changes & sibling repos
pak affected [--run] [dir]       # Print (or execute) ONLY unit tests impacted by current git diff
pak check [dir]                  # Run all contract, duplicate, dependency, codegen, i18n & evolution gates
pak uninstall [--purge] [dir]    # Cleanly remove pak hooks, skills, cache, atlas & rule blocks
pak uninstall-cli                # Remove ~/.local/bin/pak, shell PATH blocks & local project registry
```

### Unified Zero-Friction `pak upgrade` (System CLI + All Projects at Once)
You never have to `cd` into individual repositories or separate system upgrades from project upgrades. `pak` maintains a lightweight local project registry (`~/.config/pak/registry.json`, combined with automatic shallow workspace discovery and `git clone` self-healing):
- Run **`pak upgrade`** from **any directory on your computer** (even `~/`):
  1. **System Self-Upgrade:** Fast-forwards your system `pak` installation from `origin/main` (skipping safely if you have local uncommitted edits or are offline) and re-execs the updated CLI immediately.
  2. **All-Projects Sync:** Automatically upgrades `scripts/pak/*`, `SKILL.md` files, `<!-- PAK:START -->` blocks, lifecycle hooks, `"pak_version"`, and `.pak/index.sqlite` across **every `pak`-enabled project on your machine** in `<1s`—**while strictly preserving** all project-owned rules in `pak.config.json`, `docs/domains/*.md`, and `dependency-matrix.md`.
  *(Pass `pak upgrade ./my-svc` to target a single repo, `--self-only` for CLI only, or `--projects-only` to skip `git pull`.)*
- Run **`pak status`** from outside a repository to view a dashboard of all `pak`-managed projects on your machine, or inside a repository (including any nested subdirectory) for detailed stats.

---

## 7. Configuration Reference (`pak.config.json` & Environment Flags)

See [`examples/pak.config.fullstack.json`](./examples/pak.config.fullstack.json) for a complete production example:

| Key | Description |
| :--- | :--- |
| `pak_version` | Installed `pak` template/engine version stamped in the repository (used by `pak status` & `pak upgrade`). |
| `project_name` | Logical service/project identifier exported in `docs/atlas/contracts.json`. |
| `agents` | Configured AI ecosystems (`["google", "anthropic", "openai"]`). |
| `hooks_mode` | Active automated gate mode (`"both"`, `"ai"`, `"git"`, or `"none"`). |
| `linked_repos` | Relative or absolute paths to sibling microservice repositories for cross-service impact checks. |
| `test_runners` | Optional `{ "go"\|"ts"\|"py": "<cmd {targets}>" }` overrides for `pak affected --run` (e.g., Docker containers when binaries live outside host `PATH`). |
| `quarantined_paths` | Dead prototype folders or obsolete SQL dumps excluded from indexing and blocked from edits. |
| `generated_paths` | Build/codegen directories skipped during symbol indexing (`dist`, `gen`, `sqlc`, `node_modules`). |
| `codegen_pairs` | `{ "name", "source_regex", "generated_regex", "remedy" }` rules enforcing fresh code generation. |
| `checks.enforce_uuid_v7` | Blocks `uuid.New()` / `uuidv4()` / `crypto.randomUUID()` calls when `true`. |
| `checks.detect_duplicate_symbols` | Mechanically detects newly added functions whose normalized stem duplicates an existing helper. |
| `checks.detect_breaking_contracts` | Blocks wire-breaking `.proto` tag/RPC deletions and unacknowledged `DROP COLUMN` migrations. |
| `checks.cochange_min_commits` | Minimum shared commits in `git log` (default `3`) to record a hidden temporal coupling. |
| `checks.cochange_min_confidence` | Minimum conditional probability $P(B \mid A)$ (default `0.65`) for git co-change pairs. |
| `checks.i18n_locales_dir` | Directory of `<locale>.json` files verified for 100% key parity & non-empty values against `i18n_base_locale`. |
| `checks.i18n_check_code_refs` | Scans TS/TSX source files for undefined `t('...')` / `tr('...')` translation keys (default `true`). |
| `checks.banned_patterns` | Custom `{ "regex", "path_regex", "message" }` architectural or UI design-token invariants. |

### Escape-Hatch & CI Environment Variables
When an intentional breaking change, distinct similarly-named function, or pure structural refactor is desired:
- `PAK_ALLOW_BREAKING=1` — Permits intentional wire-breaking Protobuf or destructive SQL migration changes (or add `-- pak:allow-destructive` inside the SQL file).
- `PAK_ALLOW_DUPLICATE=1` — Permits adding a function whose stem matches an existing function in another module.
- `PAK_STRICT_DOCS=1` — Enforces the structural-evolution dossier check as a hard error in CLI/CI mode (always active on first pass in AI `Stop` hooks).
- `PAK_ACK_NO_DOC_IMPACT=1` — Acknowledges a pure structural refactor that has zero domain-workflow impact.

---

## 8. Uninstalling `pak` (Project-Level & System-Wide)

`pak` never locks a repository in. Every rule injection and hook registration is fenced inside explicit markers so uninstallation is 100% surgical and leaves zero broken hooks or orphaned files.

### 1. Project-Level Uninstall (Safe Mode — Preserves Architectural Docs)
Run inside (or pass the path to) any `pak`-enabled project:
```bash
pak uninstall /path/to/your-project
```
What **`pak uninstall`** removes:
- **Rule blocks:** Strips only `<!-- PAK:START --> ... <!-- PAK:END -->` from `AGENTS.md`, `GEMINI.md`, and `CLAUDE.md` (preserving all of your own rules; deletes the file only if nothing else remains).
- **AI & Git lifecycle hooks:** Removes `"pak-impact-gate"` from `.agents/hooks.json`, removes the `pak` `Stop` hook entry from `.claude/settings.json`, and strips `# --- PAK:START --- ... # --- PAK:END ---` from `.git/hooks/pre-commit` (preserving any other project hooks).
- **Skills, scripts, cache & auto-generated Atlas:** Deletes `.agents/skills/pak-*`, `.claude/skills/pak-*`, `scripts/pak/`, `.pak/index.sqlite`, and `docs/atlas/` (leaving any non-`pak` skills untouched and pruning empty directories).
- **What is preserved by default:** Your human/AI-curated `docs/domains/*.md` dossiers and `pak.config.json` are kept safe.

### 2. Full Zero-Trace Project Wipe (`--purge`)
To also delete `pak.config.json` and `docs/domains/*.md` so zero trace of `pak` remains in the repository:
```bash
pak uninstall --purge /path/to/your-project
```

### 3. System-Wide CLI Uninstall (`pak uninstall-cli`)
To remove `pak` from your machine completely:
```bash
pak uninstall-cli                        # Removes ~/.local/bin/pak AND strips pak PATH blocks from ~/.zshrc, ~/.bashrc & config.fish
rm -rf ~/.local/share/project-awareness-kit ~/projects/project-awareness-kit  # Optional: delete cloned source repository
```

---

## 9. End-to-End Automated Test Suite

Run the hermetic 10-stage smoke test suite (verifies incremental SQLite caching, multi-vendor hooks, microservice federation, wire-breaking Protobuf guards, duplicate-symbol detection, `pak affected`, global `pak upgrade` from arbitrary folders, shell-aware `zsh`/`bash`/`fish` `PATH` injection, and clean `pak uninstall` / `--purge`):

```bash
bash tests/smoke_test.sh
```

## License

[MIT](./LICENSE)
