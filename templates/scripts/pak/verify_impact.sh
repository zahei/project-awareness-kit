#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# pak — Multi-Vendor Deterministic Impact, Contract, Duplicate & Evolution Gate
#
# Modes:
#   1. CLI / Git Hook:   `bash scripts/pak/verify_impact.sh`
#   2. Google AGY Hook:  `bash scripts/pak/verify_impact.sh --agy-hook`
#   3. Claude Code Hook: `bash scripts/pak/verify_impact.sh --claude-hook`
#
# Runs in <300ms locally using `.pak/index.sqlite` and consumes 0 LLM tokens when clean!
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
import sqlite3
import subprocess
import sys
from pathlib import Path

mode = sys.argv[1]
raw_payload = sys.argv[2]
strict_docs = os.environ.get("PAK_STRICT_DOCS", "0") == "1"
ack_no_doc = os.environ.get("PAK_ACK_NO_DOC_IMPACT", "0") == "1"
allow_breaking = os.environ.get("PAK_ALLOW_BREAKING", "0") == "1"
allow_duplicate = os.environ.get("PAK_ALLOW_DUPLICATE", "0") == "1"

STEM_SYNONYMS = {
    "fetch": "get", "load": "get", "retrieve": "get", "read": "get", "query": "get", "find": "get",
    "calc": "compute", "calculate": "compute",
    "fmt": "format", "render": "format",
    "parse": "decode", "unmarshal": "decode",
    "marshal": "encode", "serialize": "encode",
    "build": "create", "make": "create", "generate": "create",
    "remove": "delete", "destroy": "delete", "erase": "delete",
}


def normalize_stem(name: str) -> str:
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name)
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", s)
    tokens = [t.lower() for t in re.split(r"[_\W]+", s) if t]
    return "_".join(STEM_SYNONYMS.get(t, t) for t in tokens)


def allow_and_exit() -> None:
    if mode == "agy":
        print(json.dumps({"decision": "allow"}))
    elif mode == "claude":
        print("{}")
    sys.exit(0)


def block_and_exit(errors: list[str]) -> None:
    joined = " | ".join(errors)
    msg = f"[pak gate] Fix before finishing: {joined}"
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
advisories: list[str] = []

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

# 6. Custom Banned Patterns
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

# 7. Optional Multi-Locale i18n Key Parity (+ Empty String & Undefined Code Reference Check)
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
            empty = [k for k in base_keys & kset if not str(data[k]).strip()]
            if missing:
                i18n_issues.append(f"{lp.name} missing {len(missing)} keys (e.g. {missing[:3]})")
            if extra:
                i18n_issues.append(f"{lp.name} has {len(extra)} extra keys")
            if empty:
                i18n_issues.append(f"{lp.name} has {len(empty)} empty values")
            if len(i18n_issues) >= 4:
                break

        if checks.get("i18n_check_code_refs", True):
            gen_prefixes = [p.strip("/") for p in cfg.get("generated_paths", []) if p.strip("/")]
            key_re = re.compile(r"""\b(?:t|tr)\(\s*["']([a-zA-Z0-9_.]+)["']""")
            used_missing = set()
            scan_roots = [Path("web/src"), Path("src")]
            for sroot in scan_roots:
                if not sroot.exists():
                    continue
                for src in sroot.rglob("*"):
                    if src.suffix not in (".ts", ".tsx") or "tests" in src.parts or "__tests__" in src.parts:
                        continue
                    rel_src = src.as_posix()
                    if any(rel_src == gp or rel_src.startswith(gp + "/") for gp in gen_prefixes):
                        continue
                    for m in key_re.finditer(src.read_text(encoding="utf-8", errors="replace")):
                        if m.group(1) not in base_keys:
                            used_missing.add(f"{rel_src}:{m.group(1)}")
            if used_missing:
                i18n_issues.insert(0, f"Undefined i18n keys in TS/TSX: {sorted(used_missing)[:4]}")

        if i18n_issues:
            errors.append("i18n parity check failed: " + "; ".join(i18n_issues[:4]))

# 8. Wire-Breaking Contract & Destructive Migration Diff Guard (`detect_breaking_contracts`)
if checks.get("detect_breaking_contracts", True) and not allow_breaking:
    proto_field_re = re.compile(r"^\s*(?:repeated\s+|optional\s+)?[A-Za-z0-9_.]+\s+([A-Za-z0-9_]+)\s*=\s*([0-9]+)\s*;")
    proto_rpc_re = re.compile(r"^\s*rpc\s+([A-Za-z0-9_]+)\s*\(")
    for f in changed_files:
        if f.endswith(".proto") and Path(f).exists():
            diff = subprocess.run(["git", "diff", "-U0", "HEAD", "--", f], capture_output=True, text=True, check=False).stdout
            removed_tags: dict[str, str] = {}
            added_tags: dict[str, str] = {}
            removed_rpcs: set[str] = set()
            added_rpcs: set[str] = set()
            full_txt = Path(f).read_text(encoding="utf-8", errors="replace")
            for ln in diff.splitlines():
                if ln.startswith("---") or ln.startswith("+++"):
                    continue
                if ln.startswith("-"):
                    body = ln[1:]
                    mf = proto_field_re.match(body)
                    if mf:
                        removed_tags[mf.group(2)] = mf.group(1)
                    mr = proto_rpc_re.match(body)
                    if mr:
                        removed_rpcs.add(mr.group(1))
                elif ln.startswith("+"):
                    body = ln[1:]
                    mf = proto_field_re.match(body)
                    if mf:
                        added_tags[mf.group(2)] = mf.group(1)
                    mr = proto_rpc_re.match(body)
                    if mr:
                        added_rpcs.add(mr.group(1))
            for tag, old_name in removed_tags.items():
                if tag in added_tags and added_tags[tag] != old_name:
                    errors.append(
                        f"Wire-breaking Protobuf change in '{f}': field tag ={tag} reassigned from '{old_name}' to '{added_tags[tag]}' (set PAK_ALLOW_BREAKING=1 if intentional)."
                    )
                elif tag not in added_tags and not re.search(rf"\breserved\b[^;]*\b{tag}\b", full_txt):
                    errors.append(
                        f"Wire-breaking Protobuf change in '{f}': field '{old_name} = {tag}' removed without `reserved {tag};` (set PAK_ALLOW_BREAKING=1 if intentional)."
                    )
            for rpc in sorted(removed_rpcs - added_rpcs):
                errors.append(
                    f"Wire-breaking Protobuf change in '{f}': RPC '{rpc}' deleted (deprecate instead or set PAK_ALLOW_BREAKING=1)."
                )

        if re.search(r"migrations/.*\.sql$", f) and Path(f).exists():
            sql_txt = Path(f).read_text(encoding="utf-8", errors="replace")
            if "pak:allow-destructive" not in sql_txt:
                if f in added_files:
                    candidate_sql = sql_txt.split("-- +goose Down")[0]
                else:
                    diff = subprocess.run(["git", "diff", "-U0", "HEAD", "--", f], capture_output=True, text=True, check=False).stdout
                    candidate_sql = "\n".join(ln[1:] for ln in diff.splitlines() if ln.startswith("+") and not ln.startswith("+++"))
                if re.search(r"\b(DROP\s+COLUMN|ALTER\s+COLUMN\s+\S+\s+TYPE)\b", candidate_sql, re.IGNORECASE):
                    errors.append(
                        f"Destructive SQL migration detected in '{f}' (DROP COLUMN / ALTER COLUMN TYPE). Add '-- pak:allow-destructive' or set PAK_ALLOW_BREAKING=1 if verified safe."
                    )

# 9. Refresh Incremental SQLite Index & Atlas Files
atlas_script = Path("scripts/pak/build_atlas.py")
if atlas_script.exists():
    subprocess.run([sys.executable, str(atlas_script), "--quiet"], check=False)

# 10. Mechanical Near-Duplicate Function Detector (`detect_duplicate_symbols`)
db_path = Path(".pak/index.sqlite")
if checks.get("detect_duplicate_symbols", True) and not allow_duplicate and db_path.exists():
    new_fn_patterns = [
        re.compile(r"^\+func\s+([A-Z][A-Za-z0-9_]*)\s*\("),  # Top-level Go exported functions (excluding receiver methods)
        re.compile(r"^\+export\s+(?:async\s+)?function\s+([A-Za-z0-9_]+)\s*\("),
        re.compile(r"^\+export\s+const\s+([A-Za-z0-9_]+)\s*=\s*(?:async\s*)?\("),
        re.compile(r"^\+(?:async\s+)?def\s+([a-zA-Z][a-zA-Z0-9_]*)\s*\("),
        re.compile(r"^\+\s*pub\s+(?:async\s+)?fn\s+([a-zA-Z0-9_]+)\s*\("),
    ]
    newly_defined: list[tuple[str, str]] = []
    for f in changed_files:
        if any(tok in f.lower() for tok in ("_test.", ".test.", ".spec.", "mock", "/gen/", "/sqlc/")):
            continue
        p = Path(f)
        if not p.exists() or not p.is_file() or p.suffix not in (".go", ".ts", ".tsx", ".js", ".py", ".rs"):
            continue
        if f in added_files:
            diff_lines = ["+" + ln for ln in p.read_text(encoding="utf-8", errors="replace").splitlines()]
        else:
            diff = subprocess.run(["git", "diff", "-U0", "HEAD", "--", f], capture_output=True, text=True, check=False).stdout
            diff_lines = [ln for ln in diff.splitlines() if ln.startswith("+") and not ln.startswith("+++")]
        for ln in diff_lines:
            for rx in new_fn_patterns:
                m = rx.match(ln)
                if m:
                    fname = m.group(1)
                    if fname.lower() not in ("main", "init", "setup", "close", "String", "Error"):
                        newly_defined.append((f, fname))

    if newly_defined:
        conn = sqlite3.connect(str(db_path))
        for src_f, fname in newly_defined:
            stem = normalize_stem(fname)
            if len(stem) < 8 or "_" not in stem:
                continue
            matches = conn.execute(
                "SELECT path, line, name, signature FROM symbols WHERE norm_stem = ? AND path != ? AND kind NOT IN ('iface_method', 'method') LIMIT 3",
                (stem, src_f),
            ).fetchall()
            if matches:
                other_path, other_line, other_name, _ = matches[0]
                dup_msg = (
                    f"Potential duplicate function '{fname}' added in '{src_f}' — similar capability '{other_name}' "
                    f"already exists at '{other_path}:L{other_line}'. Reuse/extend it, or set PAK_ALLOW_DUPLICATE=1 if distinct."
                )
                if mode in ("agy", "claude"):
                    errors.append(dup_msg)
                else:
                    advisories.append(dup_msg)
        conn.close()

# 11. Federated Multi-Microservice Consumer Check (`linked_repos`)
linked_repos = cfg.get("linked_repos", [])
local_manifest_path = Path("docs/atlas/contracts.json")
if linked_repos and local_manifest_path.exists() and changed_files:
    local_manifest = json.loads(local_manifest_path.read_text(encoding="utf-8"))
    touched_set = set(changed_files)
    modified_endpoints = {
        item["endpoint"]
        for item in local_manifest.get("provides", [])
        if item.get("path") in touched_set and item.get("endpoint")
    }
    if modified_endpoints:
        cross_impacts = []
        for lr in linked_repos:
            lr_manifest_file = Path(lr).resolve() / "docs" / "atlas" / "contracts.json"
            if not lr_manifest_file.exists():
                continue
            try:
                sib = json.loads(lr_manifest_file.read_text(encoding="utf-8"))
                sib_name = sib.get("service", Path(lr).name)
                for cons in sib.get("consumes", []):
                    ep = cons.get("endpoint", "")
                    if ep in modified_endpoints:
                        cross_impacts.append(f"{sib_name} consumes '{ep}' at {lr}/{cons.get('path')}:L{cons.get('line')}")
            except Exception:
                pass
        if cross_impacts:
            advisories.append("Cross-microservice consumers affected: " + "; ".join(cross_impacts[:5]))

# 12. Self-Evolving Architecture Gate: Ensure structural/dependency evolution syncs docs/domains/ & dependency-matrix.md
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
        if f.startswith(("scripts/pak/", "docs/", ".agents/", ".claude/", ".pak/")):
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
            advisories.append(evo_msg)

if errors:
    if advisories:
        errors.extend(advisories[:2])
    block_and_exit(errors)

if mode == "cli":
    for adv in advisories:
        print(f"[pak:check] NOTE: {adv}")
    print("[pak:check] OK — All architectural invariants, contracts, duplicate checks, dependency graphs, and SQLite Atlas verified.")
else:
    allow_and_exit()
PY
