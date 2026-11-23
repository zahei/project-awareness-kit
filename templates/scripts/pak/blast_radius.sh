#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# pak — Zero-Token Blast Radius, Dependency & Dynamic Domain Tracer
# Usage: bash scripts/pak/blast_radius.sh "<symbol|table|rpc|component>"
# ==============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

QUERY="${1:-}"
if [ -z "$QUERY" ]; then
    echo "Usage: bash scripts/pak/blast_radius.sh <symbol|table|rpc|component>"
    exit 1
fi

if [ ! -f "docs/atlas/04_DEPENDENCY_GRAPH.md" ]; then
    python3 scripts/pak/build_atlas.py --quiet
fi

echo "=== 1. REUSE CATALOG & DEPENDENCY GRAPH MATCHES (docs/atlas/) ==="
grep -rn -i -E "$QUERY" docs/atlas/ 2>/dev/null | head -n 35 || echo "  (none)"

echo ""
echo "=== 2. SOURCE CODE DEFINITIONS & CALLERS ==="
python3 - "$QUERY" << 'PY'
import json, os, re, sys
from pathlib import Path

query = sys.argv[1]
rx = re.compile(query, re.IGNORECASE)
cfg = {}
if Path("pak.config.json").exists():
    try:
        cfg = json.loads(Path("pak.config.json").read_text(encoding="utf-8"))
    except Exception:
        pass

skip_dirs = {
    ".git", ".agents", ".agent", ".claude", ".codex", ".cursor",
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

for h in code_hits[:45]:
    print(h)
if not code_hits:
    print("  (none)")

print("\n=== 3. SCHEMA / CONTRACT / CONFIG REFERENCES ===")
for h in schema_hits[:25]:
    print(h)
if not schema_hits:
    print("  (none)")

print("\n=== 4. RECOMMENDED DOMAIN DOSSIERS (Dynamic Discovery via Paths Header) ===")
domains_dir = Path("docs/domains")
paths_re = re.compile(r"^>\s*\*\*Paths:\*\*\s*`?([^`\n]+)`?", re.IGNORECASE)
if domains_dir.exists():
    dossiers = sorted(domains_dir.glob("*.md"))
    matched = []
    for d in dossiers:
        txt = d.read_text(encoding="utf-8", errors="replace")
        pat_str = ""
        for ln in txt.splitlines()[:12]:
            m = paths_re.match(ln.strip())
            if m:
                pat_str = m.group(1).strip()
                break
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
    target_list = matched if matched else [d.as_posix() for d in dossiers]
    for d in target_list[:10]:
        print(f"  - {d}")
else:
    print("  - (none yet — run pak-bootstrap skill)")
PY
