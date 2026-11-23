#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# pak — SQLite FTS5, Reverse-Dependent, Federated Microservice & Domain Tracer
# Usage: bash scripts/pak/blast_radius.sh "<symbol|table|rpc|topic|component>"
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

QUERY="${1:-}"
if [ -z "$QUERY" ]; then
    echo "Usage: bash scripts/pak/blast_radius.sh <symbol|table|rpc|topic|component>"
    exit 1
fi

if [ ! -f ".pak/index.sqlite" ] || [ ! -f "docs/atlas/05_COCHANGE_AND_CONTRACTS.md" ]; then
    python3 scripts/pak/build_atlas.py --quiet
fi

exec python3 - "$QUERY" << 'PY'
import json
import os
import re
import sqlite3
import sys
from pathlib import Path

query = sys.argv[1]
rx = re.compile(query, re.IGNORECASE)

cfg = {}
if Path("pak.config.json").exists():
    try:
        cfg = json.loads(Path("pak.config.json").read_text(encoding="utf-8"))
    except Exception:
        pass

# 1. Fast SQLite Symbol + FTS5 + Dependency + Contract Lookup
print("=== 1. INDEXED SYMBOLS, CONTRACTS & REVERSE DEPENDENTS (.pak/index.sqlite) ===")
db_path = Path(".pak/index.sqlite")
atlas_hits = []
if db_path.exists():
    conn = sqlite3.connect(str(db_path))
    fts_token = re.sub(r"[^A-Za-z0-9_]", " ", query).strip()
    rows = []
    if fts_token and " " not in fts_token:
        try:
            rows = conn.execute(
                "SELECT path, name, signature FROM symbols_fts WHERE symbols_fts MATCH ? LIMIT 20",
                (f'"{fts_token}"*',),
            ).fetchall()
        except sqlite3.OperationalError:
            rows = []
    if not rows:
        rows = conn.execute(
            "SELECT path, name, signature FROM symbols WHERE name LIKE ? OR signature LIKE ? LIMIT 20",
            (f"%{query}%", f"%{query}%"),
        ).fetchall()
    for p, _, sig in rows:
        atlas_hits.append(f"[SYMBOL] {p}: `{sig}`")

    for proto, direction, ep, p, line in conn.execute(
        "SELECT protocol, direction, endpoint, path, line FROM contracts WHERE endpoint LIKE ? OR detail LIKE ? LIMIT 15",
        (f"%{query}%", f"%{query}%"),
    ):
        atlas_hits.append(f"[{proto} {direction.upper()}] `{ep}` ({p}:L{line})")

    for src, dst in conn.execute(
        "SELECT DISTINCT src_path, dst_target FROM imports WHERE dst_target LIKE ? OR src_path LIKE ? LIMIT 15",
        (f"%{query}%", f"%{query}%"),
    ):
        atlas_hits.append(f"[DEP] `{dst}` <- imported by `{src}`")
    conn.close()

if atlas_hits:
    for h in atlas_hits[:30]:
        print(" ", h)
else:
    print("  (none)")

# 2. Federated Cross-Repo / Microservice Consumer Lookup (`linked_repos`)
linked = cfg.get("linked_repos", [])
if linked:
    print("\n=== 2. FEDERATED SIBLING MICROSERVICE IMPACTS (linked_repos) ===")
    fed_hits = []
    for lr in linked:
        lr_root = Path(lr).resolve()
        manifest_path = lr_root / "docs" / "atlas" / "contracts.json"
        if not manifest_path.exists():
            continue
        try:
            m = json.loads(manifest_path.read_text(encoding="utf-8"))
            svc = m.get("service", lr_root.name)
            for kind_key in ("provides", "consumes"):
                for item in m.get(kind_key, []):
                    blob = f"{item.get('endpoint', '')} {item.get('detail', '')} {item.get('path', '')}"
                    if rx.search(blob):
                        fed_hits.append(
                            f"[{svc} {kind_key.upper()} {item.get('protocol')}] `{item.get('endpoint')}` ({lr}/{item.get('path')}:L{item.get('line')})"
                        )
        except Exception:
            pass
    if fed_hits:
        for fh in fed_hits[:20]:
            print(" ", fh)
    else:
        print("  (no cross-repo contract matches)")

# 3. Direct Source & Schema Line Occurrences + Git Co-Change Hints
skip_dirs = {
    ".git", ".pak", ".agents", ".agent", ".claude", ".codex", ".cursor",
    "node_modules", "dist", "build", ".next", "target", "vendor",
    "coverage", ".venv", "venv", "__pycache__", "docs", "locales"
}
skip_prefixes = [p.strip("/") for p in cfg.get("quarantined_paths", []) + cfg.get("generated_paths", []) if p.strip("/")]
code_exts = {".go", ".ts", ".tsx", ".js", ".jsx", ".py", ".rs", ".java", ".kt", ".cs", ".rb", ".php"}
schema_exts = {".sql", ".proto", ".prisma", ".graphql", ".gql", ".yaml", ".yml"}

code_hits, schema_hits, matched_files = [], [], set()
for dirpath, dirnames, filenames in os.walk("."):
    rel_dir = dirpath.lstrip("./")
    dirnames[:] = sorted(
        d for d in dirnames
        if d not in skip_dirs
        and not any((f"{rel_dir}/{d}".lstrip("/") == p or f"{rel_dir}/{d}".lstrip("/").startswith(p + "/")) for p in skip_prefixes)
    )
    for f in sorted(filenames):
        p = Path(dirpath) / f
        r = p.as_posix().lstrip("./")
        if r.startswith("scripts/pak/") or any(r == sp or r.startswith(sp + "/") for sp in skip_prefixes):
            continue
        ext = p.suffix.lower()
        if ext not in code_exts and ext not in schema_exts:
            continue
        try:
            for idx, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                if rx.search(line):
                    matched_files.add(r)
                    entry = f"{r}:{idx}: {line.strip()[:140]}"
                    if ext in code_exts:
                        code_hits.append(entry)
                    else:
                        schema_hits.append(entry)
        except Exception:
            pass

print("\n=== 3. SOURCE CODE CALLERS & DEFINITIONS ===")
for h in code_hits[:35]:
    print(h)
if not code_hits:
    print("  (none)")

if schema_hits:
    print("\n=== 4. SCHEMA / CONTRACT REFERENCES ===")
    for h in schema_hits[:20]:
        print(h)

# Surface hidden git co-change partners for matched files
manifest_local = Path("docs/atlas/contracts.json")
if manifest_local.exists() and matched_files:
    try:
        cochanges = json.loads(manifest_local.read_text(encoding="utf-8")).get("cochanges", [])
        co_hits = [
            f"`{c['when_editing']}` <-> `{c['also_check']}` ({int(c['confidence']*100)}% co-change across {c['co_commits']} commits)"
            for c in cochanges
            if c["when_editing"] in matched_files or c["also_check"] in matched_files
        ]
        if co_hits:
            print("\n=== 5. HIDDEN GIT CO-CHANGE PARTNERS ===")
            for ch in co_hits[:10]:
                print(" ", ch)
    except Exception:
        pass

print("\n=== RECOMMENDED DOMAIN DOSSIERS (Dynamic Discovery) ===")
domains_dir = Path("docs/domains")
paths_re = re.compile(r"^>\s*\*\*Paths:\*\*\s*`?([^`\n]+)`?", re.IGNORECASE)
summary_re = re.compile(r"^>\s*\*\*Summary:\*\*\s*(.+)$", re.IGNORECASE)
if domains_dir.exists():
    dossiers = sorted(domains_dir.glob("*.md"))
    matched = []
    summaries = {}
    for d in dossiers:
        txt = d.read_text(encoding="utf-8", errors="replace")
        pat_str = ""
        sum_str = ""
        for ln in txt.splitlines()[:12]:
            s_line = ln.strip()
            m = paths_re.match(s_line)
            if m:
                pat_str = m.group(1).strip()
            sm = summary_re.match(s_line)
            if sm:
                sum_str = sm.group(1).strip()
        if sum_str:
            summaries[d.as_posix()] = sum_str
        hit = False
        if pat_str:
            try:
                p_rx = re.compile(pat_str, re.IGNORECASE)
                if any(p_rx.search(f) for f in matched_files) or p_rx.search(query):
                    hit = True
            except re.error:
                pass
        if not hit and (rx.search(txt) or rx.search(d.stem)):
            hit = True
        if hit:
            matched.append(d.as_posix())
    for d in (matched if matched else [d.as_posix() for d in dossiers])[:10]:
        s_note = f" — {summaries[d]}" if d in summaries else ""
        print(f"  - {d}{s_note}")
else:
    print("  - (none yet — run pak-bootstrap skill)")
PY
