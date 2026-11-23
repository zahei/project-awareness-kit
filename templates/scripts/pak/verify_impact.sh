#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# pak — Multi-Vendor Deterministic Impact, Dependency & Evolution Verifier
#
# Modes:
#   1. CLI / Git Hook:   `bash scripts/pak/verify_impact.sh`
#   2. Google AGY Hook:  `bash scripts/pak/verify_impact.sh --agy-hook`
#   3. Claude Code Hook: `bash scripts/pak/verify_impact.sh --claude-hook`
#
# Consumes 0 LLM tokens when checks pass!
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

MODE="cli"
if [ "${1:-}" = "--agy-hook" ]; then
    MODE="agy"
elif [ "${1:-}" = "--claude-hook" ]; then
    MODE="claude"
fi

PAYLOAD=""
if [ "$MODE" != "cli" ]; then
    PAYLOAD="$(cat || true)"
fi

exec python3 - "$MODE" "$PAYLOAD" << 'PY'
import json
import os
import re
import subprocess
import sys
from pathlib import Path

mode = sys.argv[1]
raw_payload = sys.argv[2]
strict_docs = os.environ.get("PAK_STRICT_DOCS", "0") == "1"
ack_no_doc = os.environ.get("PAK_ACK_NO_DOC_IMPACT", "0") == "1"


def allow_and_exit() -> None:
    if mode == "agy":
        print(json.dumps({"decision": "allow"}))
    elif mode == "claude":
        print("{}")
    sys.exit(0)


def block_and_exit(errors: list[str]) -> None:
    joined = " | ".join(errors)
    msg = f"[pak impact & evolution gate] Fix before finishing: {joined}"
    if mode == "agy":
        print(json.dumps({"decision": "continue", "reason": msg}))
        sys.exit(0)
    elif mode == "claude":
        print(json.dumps({"decision": "block", "reason": msg}))
        sys.exit(0)
    else:
        print("[pak:check] FAILED:")
        for err in errors:
            print(f"  - {err}")
        sys.exit(1)


# 1. Loop-prevention guards for Google Antigravity and Anthropic Claude Code Stop hooks
if raw_payload.strip():
    try:
        data = json.loads(raw_payload)
        if mode == "agy":
            if data.get("continuationActive", False):
                allow_and_exit()
            if data.get("terminationReason", "NO_TOOL_CALL") != "NO_TOOL_CALL":
                allow_and_exit()
        elif mode == "claude":
            if data.get("stop_hook_active", False):
                allow_and_exit()
    except Exception:
        pass

# 2. Check git dirty files (if clean in hook mode, exit immediately with 0 cost)
try:
    proc = subprocess.run(["git", "status", "--porcelain", "-uall"], capture_output=True, text=True, check=False)
    status_lines = [ln for ln in proc.stdout.splitlines() if len(ln) > 3]
    changed_files = [ln[3:].strip().split(" -> ")[-1] for ln in status_lines]
    added_files = [
        ln[3:].strip().split(" -> ")[-1]
        for ln in status_lines
        if ln[:2].strip() in ("??", "A", "AM")
    ]
except Exception:
    changed_files, added_files = [], []

if mode in ("agy", "claude") and not changed_files:
    allow_and_exit()

cfg = {}
cfg_path = Path("pak.config.json")
if cfg_path.exists():
    try:
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    except Exception as exc:
        block_and_exit([f"Invalid JSON in pak.config.json: {exc}"])

errors: list[str] = []

# 3. Quarantined Dead-Path Guard
for q in cfg.get("quarantined_paths", []):
    q_norm = q.strip("/")
    if not q_norm:
        continue
    for f in changed_files:
        if f == q_norm or f.startswith(q_norm + "/"):
            errors.append(f"Quarantined legacy path modified ('{f}'). Revert it and edit authoritative files instead.")

# 4. Codegen Freshness Pairs
for pair in cfg.get("codegen_pairs", []):
    src_rx = pair.get("source_regex", "")
    gen_rx = pair.get("generated_regex", "")
    if not src_rx or not gen_rx:
        continue
    if any(re.search(src_rx, f) for f in changed_files):
        if not any(re.search(gen_rx, f) for f in changed_files):
            errors.append(f"{pair.get('name', 'Codegen')} drift: source matched '{src_rx}' without regenerated output ('{gen_rx}'). {pair.get('remedy', '')}")

checks = cfg.get("checks", {})

# 5. Optional UUIDv7 Guard
if checks.get("enforce_uuid_v7", False):
    uuid_v4_rx = re.compile(r"\b(uuid\.New|uuid\.NewString|uuidv4|crypto\.randomUUID)\s*\(")
    for f in changed_files:
        p = Path(f)
        if not p.exists() or not p.is_file() or "uuidutil" in f or "test" in f.lower():
            continue
        if p.suffix in (".go", ".ts", ".tsx", ".js", ".py", ".rs"):
            if uuid_v4_rx.search(p.read_text(encoding="utf-8", errors="replace")):
                errors.append(f"UUIDv4 call detected in '{f}' (project enforces time-ordered UUIDv7).")

# 6. Custom Banned Patterns from pak.config.json
for rule in checks.get("banned_patterns", []):
    pat = rule.get("regex", "")
    file_rx = rule.get("path_regex", ".*")
    msg = rule.get("message", f"Banned pattern '{pat}'")
    if not pat:
        continue
    compiled = re.compile(pat)
    for f in changed_files:
        if not re.search(file_rx, f):
            continue
        p = Path(f)
        if p.exists() and p.is_file():
            if compiled.search(p.read_text(encoding="utf-8", errors="replace")):
                errors.append(f"{msg} (in '{f}')")

# 7. Optional Multi-Locale i18n Key Parity
locales_dir_str = checks.get("i18n_locales_dir", "")
if locales_dir_str:
    locales_dir = Path(locales_dir_str)
    base_name = checks.get("i18n_base_locale", "en.json")
    base_path = locales_dir / base_name
    if locales_dir.exists() and base_path.exists():
        base_keys = set(json.loads(base_path.read_text(encoding="utf-8")).keys())
        i18n_issues = []
        for lp in sorted(locales_dir.glob("*.json")):
            if lp.name == base_name:
                continue
            data = json.loads(lp.read_text(encoding="utf-8"))
            kset = set(data.keys())
            missing = sorted(base_keys - kset)
            extra = sorted(kset - base_keys)
            if missing:
                i18n_issues.append(f"{lp.name} missing {len(missing)} keys (e.g. {missing[:3]})")
            if extra:
                i18n_issues.append(f"{lp.name} has {len(extra)} extra keys")
            if len(i18n_issues) >= 4:
                break
        if i18n_issues:
            errors.append("i18n parity check failed: " + "; ".join(i18n_issues))

# 8. Auto-refresh Codebase Atlas & Live Dependency Graph BEFORE checking structural drift
atlas_script = Path("scripts/pak/build_atlas.py")
if atlas_script.exists():
    subprocess.run([sys.executable, str(atlas_script), "--quiet"], check=False)

# 9. Self-Evolving Architecture Gate: Ensure structural/dependency evolution syncs docs/domains/ & dependency-matrix.md
docs_updated = any(
    f.startswith("docs/domains/") or f.endswith("dependency-matrix.md")
    for f in changed_files
)
if not docs_updated and not ack_no_doc:
    gen_prefixes = [p.strip("/") for p in cfg.get("generated_paths", []) if p.strip("/")]
    triggers = []

    for f in changed_files:
        if any(f == gp or f.startswith(gp + "/") for gp in gen_prefixes):
            continue
        if re.search(r"(\.proto|\.prisma|\.graphql|\.gql|migrations/.*\.sql|schema\.sql)$", f):
            triggers.append(f"schema/contract modified ({f})")

    for f in added_files:
        if any(f == gp or f.startswith(gp + "/") for gp in gen_prefixes):
            continue
        if f.startswith(("scripts/pak/", "docs/", ".agents/", ".claude/")):
            continue
        if any(tok in f.lower() for tok in ("_test.", ".test.", ".spec.", "/locales/")):
            continue
        if Path(f).suffix in (".go", ".ts", ".tsx", ".js", ".jsx", ".py", ".rs"):
            triggers.append(f"new source module ({f})")

    dep_file = "docs/atlas/04_DEPENDENCY_GRAPH.md"
    cat_proc = subprocess.run(["git", "cat-file", "-e", f"HEAD:{dep_file}"], capture_output=True, check=False)
    if cat_proc.returncode == 0:
        diff_proc = subprocess.run(["git", "diff", "-U0", "HEAD", "--", dep_file], capture_output=True, text=True, check=False)
        added_edges = [ln[1:].strip() for ln in diff_proc.stdout.splitlines() if ln.startswith("+- `")]
        if added_edges:
            triggers.append(f"new module dependency ({added_edges[0][:80]})")

    if triggers:
        evo_msg = (
            f"Structural/dependency evolution detected [{', '.join(triggers[:4])}], "
            "but neither 'docs/domains/*.md' nor 'dependency-matrix.md' was updated. "
            "Update the affected dossier(s) (or create a new docs/domains/<domain>.md with Paths/Summary headers if a new domain was added) "
            "and dependency-matrix.md if workflows/couplings changed."
        )
        if mode in ("agy", "claude") or strict_docs:
            errors.append(evo_msg)
        else:
            print(f"[pak:check] NOTE: {evo_msg}")

if errors:
    block_and_exit(errors)

if mode == "cli":
    print("[pak:check] OK — All architectural invariants, dependency graphs, codegen pairs, and Atlas indexes verified.")
else:
    allow_and_exit()
PY
