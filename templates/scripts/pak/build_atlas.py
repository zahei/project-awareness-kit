#!/usr/bin/env python3
"""
pak v2.0 — Incremental SQLite/FTS5 Codebase Atlas, Cross-Service Contract Manifest,
Dependency Graph & Git Co-Change Miner.

Features (100% Python 3 stdlib, 0 external dependencies, 0 LLM tokens):
  1. Incremental SQLite cache (`.pak/index.sqlite`, auto-gitignored) keyed by `(mtime_ns, size)`
     so 500k+ LOC repositories re-index changed files in <25ms.
  2. Full-text BM25 symbol search (`FTS5`) + normalized function stems for duplicate detection.
  3. Cross-language dependency & reverse-dependent graph (`04_DEPENDENCY_GRAPH.md`).
  4. Federated microservice & event-bus contract manifest (`contracts.json`) + `git log`
     temporal co-change mining (`05_COCHANGE_AND_CONTRACTS.md`).
  5. Dynamic self-routing domain discovery (`docs/domains/*.md` `> **Paths:**` headers).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
from collections import defaultdict
from itertools import combinations
from pathlib import Path
from typing import Any, Dict, Iterable, List, Set, Tuple

ROOT = Path(__file__).resolve().parents[2]
CONFIG_PATH = ROOT / "pak.config.json"
PAK_CACHE_DIR = ROOT / ".pak"
DB_PATH = PAK_CACHE_DIR / "index.sqlite"
ATLAS_DIR = ROOT / "docs" / "atlas"
DOMAINS_DIR = ROOT / "docs" / "domains"

DEFAULT_IGNORED_DIRS = {
    ".git",
    ".hg",
    ".svn",
    ".pak",
    ".agents",
    ".agent",
    ".claude",
    ".codex",
    ".cursor",
    "node_modules",
    "dist",
    "build",
    ".next",
    "out",
    "target",
    "vendor",
    "coverage",
    ".venv",
    "venv",
    "__pycache__",
    "docs",
    "scripts",
}

INDEXED_SUFFIXES = (
    ".go",
    ".ts",
    ".tsx",
    ".js",
    ".jsx",
    ".mjs",
    ".py",
    ".rs",
    ".proto",
    ".sql",
    ".prisma",
    ".graphql",
    ".gql",
    ".css",
)

STEM_SYNONYMS = {
    "fetch": "get",
    "load": "get",
    "retrieve": "get",
    "read": "get",
    "query": "get",
    "find": "get",
    "calc": "compute",
    "calculate": "compute",
    "fmt": "format",
    "render": "format",
    "parse": "decode",
    "unmarshal": "decode",
    "marshal": "encode",
    "serialize": "encode",
    "build": "create",
    "make": "create",
    "generate": "create",
    "remove": "delete",
    "destroy": "delete",
    "erase": "delete",
}


def normalize_symbol_stem(name: str) -> str:
    # Split camelCase / PascalCase / snake_case into lowercase tokens
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name)
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", s)
    tokens = [t.lower() for t in re.split(r"[_\W]+", s) if t]
    if not tokens:
        return ""
    mapped = [STEM_SYNONYMS.get(t, t) for t in tokens]
    return "_".join(mapped)


def load_config() -> Dict[str, Any]:
    if CONFIG_PATH.exists():
        try:
            return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        except Exception as exc:
            print(f"[pak:atlas] Warning: failed parsing pak.config.json ({exc}); using defaults", file=sys.stderr)
    return {
        "project_name": ROOT.name,
        "linked_repos": [],
        "quarantined_paths": [],
        "generated_paths": list(DEFAULT_IGNORED_DIRS),
        "checks": {},
    }


def rel(p: Path) -> str:
    return p.relative_to(ROOT).as_posix()


def is_skipped(rel_path: str, cfg: Dict[str, Any]) -> bool:
    norm = rel_path.replace("\\", "/").lstrip("./")
    if not norm:
        return False
    parts = norm.split("/")
    if parts[0] in DEFAULT_IGNORED_DIRS:
        return True
    for prefix in cfg.get("quarantined_paths", []) + cfg.get("generated_paths", []):
        p = prefix.strip("/").replace("\\", "/")
        if not p:
            continue
        if norm == p or norm.startswith(p + "/") or f"/{p}/" in f"/{norm}/":
            return True
    return False


def init_db() -> Tuple[sqlite3.Connection, bool]:
    PAK_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    gi = PAK_CACHE_DIR / ".gitignore"
    if not gi.exists():
        gi.write_text("*\n", encoding="utf-8")

    conn = sqlite3.connect(str(DB_PATH))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS files (
            path TEXT PRIMARY KEY,
            mtime_ns INTEGER NOT NULL,
            size INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS symbols (
            path TEXT NOT NULL,
            line INTEGER NOT NULL,
            lang TEXT NOT NULL,
            kind TEXT NOT NULL,
            name TEXT NOT NULL,
            norm_stem TEXT NOT NULL,
            signature TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_symbols_path ON symbols(path);
        CREATE INDEX IF NOT EXISTS idx_symbols_stem ON symbols(norm_stem);
        CREATE TABLE IF NOT EXISTS imports (
            src_path TEXT NOT NULL,
            dst_target TEXT NOT NULL,
            lang TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_imports_src ON imports(src_path);
        CREATE INDEX IF NOT EXISTS idx_imports_dst ON imports(dst_target);
        CREATE TABLE IF NOT EXISTS contracts (
            path TEXT NOT NULL,
            line INTEGER NOT NULL,
            protocol TEXT NOT NULL,
            direction TEXT NOT NULL,
            endpoint TEXT NOT NULL,
            detail TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_contracts_path ON contracts(path);
        CREATE TABLE IF NOT EXISTS file_meta (
            path TEXT PRIMARY KEY,
            meta_json TEXT NOT NULL
        );
        """
    )
    has_fts = False
    try:
        conn.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS symbols_fts USING fts5(name, signature, path, norm_stem)"
        )
        has_fts = True
    except sqlite3.OperationalError:
        has_fts = False
    return conn, has_fts


def read_go_module_name() -> str:
    gomod = ROOT / "go.mod"
    if gomod.exists():
        for ln in gomod.read_text(encoding="utf-8", errors="replace").splitlines():
            if ln.startswith("module "):
                return ln.split()[1].strip()
    return ""


def resolve_ts_import(src_file: Path, spec: str) -> str:
    if spec.startswith("@/"):
        for root_cand in (ROOT / "src" / spec[2:], ROOT / "web" / "src" / spec[2:]):
            for ext in ("", ".ts", ".tsx", ".js", ".jsx", "/index.ts", "/index.tsx"):
                cand = Path(str(root_cand) + ext)
                if cand.exists() and cand.is_file():
                    return rel(cand)
        return ""
    if not spec.startswith("."):
        return ""
    base = (src_file.parent / spec).resolve()
    for ext in ("", ".ts", ".tsx", ".js", ".jsx", "/index.ts", "/index.tsx", "/index.js", ".css"):
        cand = Path(str(base) + ext)
        if cand.exists() and cand.is_file():
            try:
                return cand.relative_to(ROOT).as_posix()
            except ValueError:
                return ""
    return ""


# Compiled regexes for fast single-pass file extraction
GO_TYPE_RE = re.compile(r"^type\s+([A-Z][A-Za-z0-9_]*)\s+(interface|struct|[A-Za-z0-9_\[\]*\.]+)")
GO_FUNC_RE = re.compile(r"^func\s+(?:\(([^)]+)\)\s+)?([A-Z][A-Za-z0-9_]*)\s*\(")
GO_IFACE_M_RE = re.compile(r"^\t([A-Z][A-Za-z0-9_]*)\((.*)\)\s*(.*)$")
GO_IMP_RE = re.compile(r'"([^"]+)"')
GO_HTTP_MUX_RE = re.compile(r'(?:HandleFunc|Handle|Get|Post|Put|Delete|Patch)\(\s*"(/[^"]*)"')

TS_EXP_RE = re.compile(
    r"^export\s+(?:default\s+)?(?:async\s+)?(function|const|class|interface|type|enum)\s+([A-Za-z0-9_]+)"
)
TS_IMP_RE = re.compile(r"""(?:from|import)\s*\(?['"]([^'"]+)['"]\)?""")
TS_FETCH_RE = re.compile(r"""(?:fetch|axios\.(?:get|post|put|delete|patch))\(\s*[`'"](/api/[^`'"$\s?]*)""")
TS_ROUTE_RE = re.compile(r"""\b(?:app|router)\.(get|post|put|delete|patch)\(\s*['"](/[^'"]+)['"]""")

PY_SYM_RE = re.compile(r"^(class|def|async\s+def)\s+([A-Za-z][A-Za-z0-9_]*)\s*[\(:]")
PY_IMP_RE = re.compile(r"^\s*(?:from\s+\.?([a-zA-Z0-9_]+)\s+import|import\s+([a-zA-Z0-9_]+))")
PY_ROUTE_RE = re.compile(r"""@(?:app|router)\.(get|post|put|delete|patch|route)\(\s*['"](/[^'"]+)['"]""")

RS_SYM_RE = re.compile(r"^\s*pub(?:\([^)]+\))?\s+(?:async\s+)?(fn|struct|enum|trait|type|mod)\s+([A-Za-z0-9_]+)")
RS_USE_RE = re.compile(r"^\s*use\s+crate::([a-zA-Z0-9_]+)")

EVENT_PUB_RE = re.compile(
    r"""(?:\.\s*(?:Publish|Produce|SendEvent|Emit|emit)|dispatchEvent\(\s*new\s+CustomEvent)\(\s*['"]([a-zA-Z0-9_.:-]+)['"]"""
)
EVENT_SUB_RE = re.compile(
    r"""(?:\.\s*(?:Subscribe|Consume|On|on)|@EventPattern|@MessagePattern|addEventListener)\(\s*['"]([a-zA-Z0-9_.:-]+)['"]"""
)

PROTO_SVC_RE = re.compile(r"^service\s+([A-Za-z0-9_]+)")
PROTO_RPC_RE = re.compile(r"^\s*rpc\s+([A-Za-z0-9_]+)\s*\(([^)]+)\)\s*returns\s*\(([^)]+)\)")
PROTO_MSG_RE = re.compile(r"^message\s+([A-Za-z0-9_]+)")

SQL_DDL_RE = re.compile(
    r"CREATE\s+(?:OR\s+REPLACE\s+)?(TABLE|VIEW)\s+(?:IF\s+NOT\s+EXISTS\s+)?([A-Za-z0-9_.\"']+)",
    re.IGNORECASE,
)
SQLC_RE = re.compile(r"^--\s*name:\s*([A-Za-z0-9_]+)\s*(:[a-z]+)")
SCHEMA_MODEL_RE = re.compile(r"^(model|enum|type|input|interface)\s+([A-Za-z0-9_]+)")
CSS_THEME_RE = re.compile(r'\[data-theme="([^"]+)"\]')
CSS_VAR_RE = re.compile(r"(--[a-zA-Z0-9_-]+)\s*:")
CSS_MN_RE = re.compile(r"\.(mn-[a-z0-9-]+)\s*\{")


def parse_single_file(
    p: Path,
    r: str,
    go_mod_prefix: str,
    py_stems: Dict[str, str],
    cfg: Dict[str, Any],
) -> Tuple[List[Tuple[Any, ...]], List[Tuple[str, str, str]], List[Tuple[Any, ...]], Dict[str, Any]]:
    symbols: List[Tuple[Any, ...]] = []
    imports: List[Tuple[str, str, str]] = []
    contracts: List[Tuple[Any, ...]] = []
    meta: Dict[str, Any] = {}

    ext = p.suffix.lower()
    txt = p.read_text(encoding="utf-8", errors="replace")
    lines = txt.splitlines()
    is_test = (
        r.endswith("_test.go")
        or any(seg in p.name for seg in (".test.", ".spec.", ".stories."))
        or p.name.startswith("test_")
        or p.name.endswith("_test.py")
        or "/tests/" in f"/{r}/"
    )

    # Event-bus pub/sub scan across code files
    if ext in (".go", ".ts", ".tsx", ".js", ".jsx", ".py", ".rs") and not is_test:
        for idx, ln in enumerate(lines, 1):
            for m in EVENT_PUB_RE.finditer(ln):
                topic = m.group(1)
                if topic not in ("click", "change", "keydown", "keyup", "focus", "blur", "submit", "resize", "scroll", "popstate", "load", "error"):
                    contracts.append((r, idx, "EVENT", "publishes", topic, ln.strip()[:120]))
            for m in EVENT_SUB_RE.finditer(ln):
                topic = m.group(1)
                if topic not in ("click", "change", "keydown", "keyup", "focus", "blur", "submit", "resize", "scroll", "popstate", "load", "error"):
                    contracts.append((r, idx, "EVENT", "subscribes", topic, ln.strip()[:120]))

    if ext == ".go" and not is_test:
        pkg_dir = p.parent.relative_to(ROOT).as_posix()
        in_iface = ""
        i = 0
        while i < len(lines):
            ln = lines[i]
            m_mux = GO_HTTP_MUX_RE.search(ln)
            if m_mux:
                contracts.append((r, i + 1, "HTTP", "provides", m_mux.group(1), ln.strip()[:120]))
            if in_iface:
                if ln.startswith("}"):
                    in_iface = ""
                else:
                    mm = GO_IFACE_M_RE.match(ln)
                    if mm:
                        sig = f"{in_iface}.{mm.group(1)}({mm.group(2)}) {mm.group(3).strip()}".strip()
                        symbols.append((r, i + 1, "go", "iface_method", f"{in_iface}.{mm.group(1)}", normalize_symbol_stem(mm.group(1)), sig))
                i += 1
                continue
            mt = GO_TYPE_RE.match(ln)
            if mt:
                symbols.append((r, i + 1, "go", f"type:{mt.group(2)}", mt.group(1), normalize_symbol_stem(mt.group(1)), f"type {mt.group(1)} {mt.group(2)}"))
                if mt.group(2) == "interface" and "{" in ln and not ln.rstrip().endswith("}"):
                    in_iface = mt.group(1)
                i += 1
                continue
            mf = GO_FUNC_RE.match(ln)
            if mf:
                recv, fname = mf.group(1) or "", mf.group(2)
                sig_parts = [ln.strip()]
                j = i
                while not sig_parts[-1].endswith("{") and j + 1 < len(lines) and (j - i) < 6:
                    j += 1
                    sig_parts.append(lines[j].strip())
                sig = re.sub(r"\s+", " ", " ".join(sig_parts)).rstrip("{").strip()
                kind = "method" if recv else "func"
                symbols.append((r, i + 1, "go", kind, fname, normalize_symbol_stem(fname), sig))
                i = j + 1
                continue
            i += 1

        if go_mod_prefix:
            for m in GO_IMP_RE.finditer(txt):
                imp = m.group(1)
                if imp.startswith(go_mod_prefix):
                    dep_pkg = imp[len(go_mod_prefix):]
                    if dep_pkg != pkg_dir and not is_skipped(dep_pkg, cfg):
                        imports.append((pkg_dir, dep_pkg, "go"))

    elif ext in (".ts", ".tsx", ".js", ".jsx", ".mjs") and not is_test and not p.name.endswith(".d.ts") and "/locales/" not in r:
        for idx, ln in enumerate(lines, 1):
            m = TS_EXP_RE.match(ln.strip())
            if m:
                symbols.append((r, idx, "ts", m.group(1), m.group(2), normalize_symbol_stem(m.group(2)), f"{m.group(1)} {m.group(2)}"))
            mr = TS_ROUTE_RE.search(ln)
            if mr:
                contracts.append((r, idx, "HTTP", "provides", f"{mr.group(1).upper()} {mr.group(2)}", ln.strip()[:120]))
            mf = TS_FETCH_RE.search(ln)
            if mf:
                contracts.append((r, idx, "HTTP", "consumes", mf.group(1), ln.strip()[:120]))
        for m in TS_IMP_RE.finditer(txt):
            resolved = resolve_ts_import(p, m.group(1))
            if resolved and resolved != r and not is_skipped(resolved, cfg) and "/locales/" not in resolved:
                imports.append((r, resolved, "ts"))

    elif ext == ".py" and not is_test and p.name != "__init__.py":
        for idx, ln in enumerate(lines, 1):
            ms = PY_SYM_RE.match(ln)
            if ms and not ms.group(2).startswith("_"):
                kind = "fn" if "def" in ms.group(1) else "class"
                symbols.append((r, idx, "py", kind, ms.group(2), normalize_symbol_stem(ms.group(2)), f"{kind} {ms.group(2)}"))
            mr = PY_ROUTE_RE.search(ln)
            if mr:
                contracts.append((r, idx, "HTTP", "provides", f"{mr.group(1).upper()} {mr.group(2)}", ln.strip()[:120]))
            mi = PY_IMP_RE.match(ln)
            if mi:
                mod = (mi.group(1) or mi.group(2)).split(".")[0]
                if mod in py_stems and py_stems[mod] != r:
                    imports.append((r, py_stems[mod], "py"))

    elif ext == ".rs" and not is_test:
        for idx, ln in enumerate(lines, 1):
            ms = RS_SYM_RE.match(ln)
            if ms:
                symbols.append((r, idx, "rs", ms.group(1), ms.group(2), normalize_symbol_stem(ms.group(2)), f"{ms.group(1)} {ms.group(2)}"))
            mu = RS_USE_RE.match(ln)
            if mu:
                imports.append((r, f"crate::{mu.group(1)}", "rs"))

    elif ext == ".proto":
        cur_svc = ""
        msgs = []
        for idx, ln in enumerate(lines, 1):
            ms = PROTO_SVC_RE.match(ln.strip())
            if ms:
                cur_svc = ms.group(1)
                continue
            mr = PROTO_RPC_RE.match(ln)
            if mr:
                prefix = f"{cur_svc}." if cur_svc else ""
                rpc_id = f"{prefix}{mr.group(1)}"
                detail = f"({mr.group(2).strip()}) -> {mr.group(3).strip()}"
                contracts.append((r, idx, "PROTO_RPC", "provides", rpc_id, detail))
                continue
            mm = PROTO_MSG_RE.match(ln.strip())
            if mm:
                msgs.append(mm.group(1))
        meta["proto_messages"] = msgs

    elif ext == ".sql":
        up_txt = txt.split("-- +goose Down")[0]
        ddls = []
        for m in SQL_DDL_RE.finditer(up_txt):
            kind, tname = m.group(1).upper(), m.group(2)
            ddls.append(f"{kind} {tname}")
            contracts.append((r, 1, "SQL_SCHEMA", "provides", tname.strip('"`\''), kind))
        queries = []
        for idx, ln in enumerate(lines, 1):
            mq = SQLC_RE.match(ln.strip())
            if mq:
                queries.append(f"`{mq.group(1)}` ({mq.group(2)})")
                symbols.append((r, idx, "sqlc", "query", mq.group(1), normalize_symbol_stem(mq.group(1)), f"{mq.group(1)} {mq.group(2)}"))
        meta["sql_ddls"] = ddls
        meta["sql_queries"] = queries

    elif ext in (".prisma", ".graphql", ".gql"):
        defs = []
        for idx, ln in enumerate(lines, 1):
            m = SCHEMA_MODEL_RE.match(ln.strip())
            if m:
                defs.append(f"`{m.group(1)} {m.group(2)}` (L{idx})")
                contracts.append((r, idx, ext.lstrip(".").upper(), "provides", m.group(2), m.group(1)))
        meta["schema_defs"] = defs

    elif ext == ".css":
        meta["themes"] = sorted(set(CSS_THEME_RE.findall(txt)))
        meta["css_vars"] = sorted(set(CSS_VAR_RE.findall(txt)))
        meta["mn_classes"] = sorted(set(CSS_MN_RE.findall(txt)))

    return symbols, imports, contracts, meta


def sync_incremental_index(conn: sqlite3.Connection, has_fts: bool, cfg: Dict[str, Any]) -> Tuple[int, int]:
    """Incrementally updates `.pak/index.sqlite` in milliseconds based on `(mtime_ns, size)`."""
    live_files: Dict[str, Tuple[Path, int, int]] = {}
    py_stems: Dict[str, str] = {}

    for dirpath, dirnames, filenames in os.walk(ROOT):
        d_path = Path(dirpath)
        d_rel = "" if d_path == ROOT else rel(d_path)
        dirnames[:] = sorted(
            d for d in dirnames
            if d not in DEFAULT_IGNORED_DIRS
            and not d.startswith(".")
            and not is_skipped(f"{d_rel}/{d}".lstrip("/"), cfg)
        )
        for fname in sorted(filenames):
            if not fname.endswith(INDEXED_SUFFIXES):
                continue
            full = d_path / fname
            r = rel(full)
            if is_skipped(r, cfg):
                continue
            try:
                st = full.stat()
            except OSError:
                continue
            live_files[r] = (full, st.st_mtime_ns, st.st_size)
            if full.suffix == ".py" and not fname.startswith("__"):
                py_stems[full.stem] = r

    cached_rows = {
        row[0]: (row[1], row[2])
        for row in conn.execute("SELECT path, mtime_ns, size FROM files")
    }

    deleted_paths = set(cached_rows.keys()) - set(live_files.keys())
    dirty_paths = [
        r for r, (_, mtime_ns, size) in live_files.items()
        if cached_rows.get(r) != (mtime_ns, size)
    ]

    if not deleted_paths and not dirty_paths:
        return len(live_files), 0

    go_mod = read_go_module_name()
    go_prefix = (go_mod + "/") if go_mod else ""

    with conn:
        for dead in deleted_paths:
            conn.execute("DELETE FROM files WHERE path = ?", (dead,))
            conn.execute("DELETE FROM symbols WHERE path = ?", (dead,))
            conn.execute("DELETE FROM imports WHERE src_path = ?", (dead,))
            conn.execute("DELETE FROM contracts WHERE path = ?", (dead,))
            conn.execute("DELETE FROM file_meta WHERE path = ?", (dead,))
            if has_fts:
                conn.execute("DELETE FROM symbols_fts WHERE path = ?", (dead,))

        for r in dirty_paths:
            p, mtime_ns, size = live_files[r]
            pkg_dir = p.parent.relative_to(ROOT).as_posix() if p.suffix == ".go" else r
            conn.execute("DELETE FROM symbols WHERE path = ?", (r,))
            conn.execute("DELETE FROM imports WHERE src_path = ?", (pkg_dir if p.suffix == ".go" else r,))
            conn.execute("DELETE FROM contracts WHERE path = ?", (r,))
            conn.execute("DELETE FROM file_meta WHERE path = ?", (r,))
            if has_fts:
                conn.execute("DELETE FROM symbols_fts WHERE path = ?", (r,))

            syms, imps, cts, meta = parse_single_file(p, r, go_prefix, py_stems, cfg)
            # Note: For Go packages with multiple files in the same dir, re-collect all Go files in pkg_dir if needed
            if syms:
                conn.executemany(
                    "INSERT INTO symbols(path, line, lang, kind, name, norm_stem, signature) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    syms,
                )
                if has_fts:
                    conn.executemany(
                        "INSERT INTO symbols_fts(name, signature, path, norm_stem) VALUES (?, ?, ?, ?)",
                        [(s[4], s[6], s[0], s[5]) for s in syms],
                    )
            if p.suffix != ".go" and imps:
                conn.executemany("INSERT INTO imports(src_path, dst_target, lang) VALUES (?, ?, ?)", imps)
            if cts:
                conn.executemany(
                    "INSERT INTO contracts(path, line, protocol, direction, endpoint, detail) VALUES (?, ?, ?, ?, ?, ?)",
                    cts,
                )
            if meta:
                conn.execute("INSERT INTO file_meta(path, meta_json) VALUES (?, ?)", (r, json.dumps(meta)))
            conn.execute(
                "INSERT OR REPLACE INTO files(path, mtime_ns, size) VALUES (?, ?, ?)",
                (r, mtime_ns, size),
            )

        # Refresh Go package-level imports cleanly when any .go file changed
        if any(r.endswith(".go") for r in dirty_paths) or any(r.endswith(".go") for r in deleted_paths):
            conn.execute("DELETE FROM imports WHERE lang = 'go'")
            if go_prefix:
                go_edges: Set[Tuple[str, str, str]] = set()
                for r, (p, _, _) in live_files.items():
                    if not r.endswith(".go") or r.endswith("_test.go"):
                        continue
                    pkg_dir = p.parent.relative_to(ROOT).as_posix()
                    for m in GO_IMP_RE.finditer(p.read_text(encoding="utf-8", errors="replace")):
                        imp = m.group(1)
                        if imp.startswith(go_prefix):
                            dep = imp[len(go_prefix):]
                            if dep != pkg_dir and not is_skipped(dep, cfg):
                                go_edges.add((pkg_dir, dep, "go"))
                if go_edges:
                    conn.executemany("INSERT INTO imports(src_path, dst_target, lang) VALUES (?, ?, ?)", sorted(go_edges))

    return len(live_files), len(dirty_paths) + len(deleted_paths)


def render_code_capabilities(conn: sqlite3.Connection) -> str:
    out: List[str] = [
        "# Code Capabilities & Symbol Reuse Index",
        "",
        "> Auto-generated incrementally via `.pak/index.sqlite` by `scripts/pak/build_atlas.py`.",
        "> **Anti-Duplication Rule:** Run `pak trace <term>` (or search this index) BEFORE writing any new helper, query, hook, or component.",
        "",
    ]

    # Go
    go_rows = conn.execute(
        "SELECT path, line, kind, signature FROM symbols WHERE lang = 'go' ORDER BY path, line"
    ).fetchall()
    if go_rows:
        out.append("## Go Packages & Exported Symbols")
        cur_path = ""
        for path, line, kind, sig in go_rows:
            if path != cur_path:
                cur_path = path
                out.append(f"\n### `{path}`")
            indent = "  - " if kind == "iface_method" else "- "
            out.append(f"{indent}L{line} `{sig}`")
        out.append("")

    # TS/JS
    ts_rows = conn.execute(
        "SELECT path, line, kind, name FROM symbols WHERE lang = 'ts' ORDER BY path, line"
    ).fetchall()
    if ts_rows:
        out.append("## TypeScript / JavaScript Exports")
        by_file: Dict[str, List[str]] = defaultdict(list)
        for path, line, kind, name in ts_rows:
            by_file[path].append(f"`{name}` ({kind}, L{line})")
        for path in sorted(by_file):
            out.append(f"- `{path}`: " + ", ".join(by_file[path]))
        out.append("")

    # Python
    py_rows = conn.execute(
        "SELECT path, line, kind, name FROM symbols WHERE lang = 'py' ORDER BY path, line"
    ).fetchall()
    if py_rows:
        out.append("## Python Modules, Classes & Functions")
        by_file = defaultdict(list)
        for path, line, kind, name in py_rows:
            by_file[path].append(f"`{name}` ({kind}, L{line})")
        for path in sorted(by_file):
            out.append(f"- `{path}`: " + ", ".join(by_file[path]))
        out.append("")

    # Rust
    rs_rows = conn.execute(
        "SELECT path, line, kind, name FROM symbols WHERE lang = 'rs' ORDER BY path, line"
    ).fetchall()
    if rs_rows:
        out.append("## Rust Public Symbols")
        by_file = defaultdict(list)
        for path, line, kind, name in rs_rows:
            by_file[path].append(f"`{name}` ({kind}, L{line})")
        for path in sorted(by_file):
            out.append(f"- `{path}`: " + ", ".join(by_file[path]))
        out.append("")

    if len(out) <= 6:
        out.append("_(No source symbols indexed yet.)_\n")

    return "\n".join(out).rstrip() + "\n"


def render_data_contracts(conn: sqlite3.Connection) -> str:
    out: List[str] = [
        "# Data Contracts: APIs, Schemas & Queries",
        "",
        "> Auto-generated incrementally by `scripts/pak/build_atlas.py`.",
        "",
    ]

    metas = {
        path: json.loads(mjson)
        for path, mjson in conn.execute("SELECT path, meta_json FROM file_meta ORDER BY path")
    }

    proto_rpcs = conn.execute(
        "SELECT path, line, endpoint, detail FROM contracts WHERE protocol = 'PROTO_RPC' ORDER BY path, line"
    ).fetchall()
    proto_paths = sorted(set(r[0] for r in proto_rpcs) | {p for p, m in metas.items() if "proto_messages" in m})
    if proto_paths:
        out.append("## Protobuf Services & RPCs")
        rpcs_by_p: Dict[str, List[str]] = defaultdict(list)
        for path, line, ep, detail in proto_rpcs:
            rpcs_by_p[path].append(f"  - L{line} `{ep}{detail}`")
        for p in proto_paths:
            out.append(f"\n### `{p}`")
            out.extend(rpcs_by_p.get(p, []))
            msgs = metas.get(p, {}).get("proto_messages", [])
            if msgs:
                out.append(f"  - Messages ({len(msgs)}): " + ", ".join(f"`{m}`" for m in msgs[:40]))
        out.append("")

    http_routes = conn.execute(
        "SELECT path, line, direction, endpoint FROM contracts WHERE protocol = 'HTTP' ORDER BY direction, path, line"
    ).fetchall()
    if http_routes:
        out.append("## HTTP Endpoints (Provided & Consumed)")
        for path, line, direction, ep in http_routes:
            out.append(f"- [{direction.upper()}] `{ep}` (`{path}:L{line}`)")
        out.append("")

    sql_paths = [p for p, m in metas.items() if m.get("sql_ddls") or m.get("sql_queries")]
    if sql_paths:
        out.append("## SQL Tables, Views & Typed Queries")
        for p in sql_paths:
            m = metas[p]
            items = [f"`{d}`" for d in m.get("sql_ddls", [])] + m.get("sql_queries", [])
            out.append(f"- `{p}`: " + ", ".join(items))
        out.append("")

    schema_paths = [p for p, m in metas.items() if m.get("schema_defs")]
    if schema_paths:
        out.append("## Prisma / GraphQL Models & Operations")
        for p in schema_paths:
            out.append(f"- `{p}`: " + ", ".join(metas[p]["schema_defs"]))
        out.append("")

    if len(out) <= 5:
        out.append("_(No SQL, HTTP, Protobuf, Prisma, or GraphQL contracts detected yet.)_\n")

    return "\n".join(out).rstrip() + "\n"


def render_ui_and_i18n(conn: sqlite3.Connection, cfg: Dict[str, Any]) -> str:
    out: List[str] = [
        "# UI Design Tokens & Localization Summary",
        "",
        "> Auto-generated by `scripts/pak/build_atlas.py`.",
        "",
    ]

    css_metas = [
        (path, json.loads(mjson))
        for path, mjson in conn.execute("SELECT path, meta_json FROM file_meta WHERE path LIKE '%.css' ORDER BY path")
    ]
    if css_metas:
        out.append("## CSS Custom Properties & Themes")
        for path, m in css_metas:
            themes, css_vars, mn_cls = m.get("themes", []), m.get("css_vars", []), m.get("mn_classes", [])
            if themes or css_vars or mn_cls:
                out.append(f"### `{path}`")
                if themes:
                    out.append("- Themes: " + ", ".join(f"`{t}`" for t in themes))
                if mn_cls:
                    out.append("- Semantic Classes: " + ", ".join(f"`.{c}`" for c in mn_cls))
                if css_vars:
                    sample = ", ".join(f"`{v}`" for v in css_vars[:35])
                    more = f" (+{len(css_vars) - 35} more)" if len(css_vars) > 35 else ""
                    out.append(f"- CSS Tokens ({len(css_vars)}): {sample}{more}")
        out.append("")

    i18n_dir_rel = cfg.get("checks", {}).get("i18n_locales_dir", "")
    if i18n_dir_rel:
        locales_dir = ROOT / i18n_dir_rel
        base_file = locales_dir / cfg.get("checks", {}).get("i18n_base_locale", "en.json")
        if locales_dir.exists() and base_file.exists():
            locale_codes = sorted(p.stem for p in locales_dir.glob("*.json"))
            base_data = json.loads(base_file.read_text(encoding="utf-8"))
            out.append("## Localization (`i18n`)")
            out.append(f"- Directory: `{i18n_dir_rel}` ({len(locale_codes)} locales)")
            out.append(f"- Keys in `{base_file.name}`: `{len(base_data)}`")
            out.append("- Locales: " + ", ".join(f"`{c}`" for c in locale_codes))
            out.append("")

    if len(out) <= 5:
        out.append("_(No CSS token sheets or i18n locale catalogs configured.)_\n")

    return "\n".join(out).rstrip() + "\n"


def render_dependency_graph(conn: sqlite3.Connection) -> Tuple[str, Set[Tuple[str, str]]]:
    out: List[str] = [
        "# Live Module Dependency & Reverse-Dependent Graph",
        "",
        "> Auto-generated from `.pak/index.sqlite` by `scripts/pak/build_atlas.py`.",
        "> Check **Reverse Dependents** (`<-`) before modifying any shared package, module, or component.",
        "",
    ]

    all_direct_pairs: Set[Tuple[str, str]] = set()

    for lang_code, label in [
        ("go", "Go Internal Package Dependencies"),
        ("ts", "TypeScript / JavaScript Module Dependencies"),
        ("py", "Python Internal Module Dependencies"),
        ("rs", "Rust Crate Module Dependencies"),
    ]:
        rows = conn.execute(
            "SELECT DISTINCT src_path, dst_target FROM imports WHERE lang = ? ORDER BY src_path, dst_target",
            (lang_code,),
        ).fetchall()
        if not rows:
            continue
        deps: Dict[str, List[str]] = defaultdict(list)
        rev: Dict[str, List[str]] = defaultdict(list)
        for src, dst in rows:
            deps[src].append(dst)
            rev[dst].append(src)
            all_direct_pairs.add((src, dst))
            all_direct_pairs.add((dst, src))

        out.append(f"## {label}")
        out.append("### Reverse Dependents (`Target <- Importers`)")
        for target in sorted(rev):
            out.append(f"- `{target}` <- " + ", ".join(f"`{c}`" for c in rev[target]))
        if lang_code == "go":
            out.append("\n### Outbound Imports (`Package -> Dependencies`)")
            for src in sorted(deps):
                out.append(f"- `{src}` -> " + ", ".join(f"`{d}`" for d in deps[src]))
        out.append("")

    if len(out) <= 6:
        out.append("_(No internal cross-module imports detected yet.)_\n")

    return "\n".join(out).rstrip() + "\n", all_direct_pairs


def mine_git_cochanges(
    cfg: Dict[str, Any],
    direct_import_pairs: Set[Tuple[str, str]],
) -> List[Dict[str, Any]]:
    """Mines git log to discover hidden cross-file couplings invisible to static imports."""
    if not (ROOT / ".git").exists():
        return []
    checks = cfg.get("checks", {})
    min_commits = int(checks.get("cochange_min_commits", 3))
    min_conf = float(checks.get("cochange_min_confidence", 0.65))

    try:
        proc = subprocess.run(
            ["git", "log", "--name-only", "--pretty=format:---COMMIT---", "-n", "250"],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
    except Exception:
        return []

    commits: List[List[str]] = []
    cur: Set[str] = set()
    for raw in proc.stdout.splitlines():
        ln = raw.strip()
        if ln == "---COMMIT---":
            if 2 <= len(cur) <= 20:
                commits.append(sorted(cur))
            cur = set()
            continue
        if not ln or is_skipped(ln, cfg):
            continue
        if ln.startswith(("docs/atlas/", ".agents/", ".claude/")) or "/locales/" in ln:
            continue
        cur.add(ln)
    if 2 <= len(cur) <= 20:
        commits.append(sorted(cur))

    file_counts: Dict[str, int] = defaultdict(int)
    pair_counts: Dict[Tuple[str, str], int] = defaultdict(int)
    for files in commits:
        for f in files:
            file_counts[f] += 1
        for a, b in combinations(files, 2):
            # Ignore obvious unit test twins (foo.go <-> foo_test.go)
            a_stem = re.sub(r"(_test|\.test|\.spec)", "", Path(a).stem)
            b_stem = re.sub(r"(_test|\.test|\.spec)", "", Path(b).stem)
            if a_stem == b_stem and Path(a).parent == Path(b).parent:
                continue
            if (a, b) in direct_import_pairs or (b, a) in direct_import_pairs:
                continue
            pair_counts[(a, b)] += 1

    results: List[Dict[str, Any]] = []
    for (a, b), co_cnt in pair_counts.items():
        if co_cnt < min_commits:
            continue
        if not (ROOT / a).exists() or not (ROOT / b).exists():
            continue
        conf_ab = co_cnt / max(1, file_counts[a])
        conf_ba = co_cnt / max(1, file_counts[b])
        max_conf = max(conf_ab, conf_ba)
        if max_conf >= min_conf:
            primary, partner, conf = (a, b, conf_ab) if conf_ab >= conf_ba else (b, a, conf_ba)
            results.append(
                {
                    "when_editing": primary,
                    "also_check": partner,
                    "co_commits": co_cnt,
                    "total_commits": file_counts[primary],
                    "confidence": round(conf, 2),
                }
            )

    results.sort(key=lambda x: (-x["confidence"], -x["co_commits"], x["when_editing"]))
    return results[:40]


def export_contracts_and_cochange(
    conn: sqlite3.Connection,
    cfg: Dict[str, Any],
    cochanges: List[Dict[str, Any]],
) -> str:
    rows = conn.execute(
        "SELECT protocol, direction, endpoint, path, line, detail FROM contracts ORDER BY protocol, direction, endpoint"
    ).fetchall()

    manifest = {
        "service": cfg.get("project_name", ROOT.name),
        "root": str(ROOT),
        "provides": [
            {"protocol": r[0], "endpoint": r[2], "path": r[3], "line": r[4], "detail": r[5]}
            for r in rows
            if r[1] in ("provides", "publishes")
        ],
        "consumes": [
            {"protocol": r[0], "endpoint": r[2], "path": r[3], "line": r[4], "detail": r[5]}
            for r in rows
            if r[1] in ("consumes", "subscribes")
        ],
        "cochanges": cochanges,
    }
    (ATLAS_DIR / "contracts.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    out: List[str] = [
        "# Service Contracts, Event-Bus Topics & Hidden Git Co-Change Couplings",
        "",
        "> Auto-generated by `scripts/pak/build_atlas.py` (+ machine-readable `docs/atlas/contracts.json` for multi-repo federation).",
        "",
        "## 1. Event-Bus & CustomEvent Pub/Sub Channels",
    ]

    events = [r for r in rows if r[0] == "EVENT"]
    if events:
        for _, direction, ep, path, line, _ in events:
            out.append(f"- **{direction.upper()}** `{ep}` (`{path}:L{line}`)")
    else:
        out.append("- _(No pub/sub event topics detected.)_")

    out.append("\n## 2. Linked Sibling Microservice Repositories (`linked_repos`)")
    linked = cfg.get("linked_repos", [])
    if linked:
        for lr in linked:
            lr_path = (ROOT / lr).resolve()
            m_file = lr_path / "docs" / "atlas" / "contracts.json"
            status = "manifest indexed" if m_file.exists() else "manifest missing (run `pak atlas` in repo)"
            out.append(f"- `{lr}` -> `{lr_path.name}` ({status})")
    else:
        out.append("- _(Single-repo mode — add sibling paths to `\"linked_repos\"` in `pak.config.json` to enable cross-service impact checks.)_")

    out.append("\n## 3. Hidden Temporal Couplings Mined from `git log` (Non-Import Co-Changes)")
    if cochanges:
        for item in cochanges[:25]:
            pct = int(round(item["confidence"] * 100))
            out.append(
                f"- Editing `{item['when_editing']}` -> check `{item['also_check']}` "
                f"*(co-changed in {item['co_commits']}/{item['total_commits']} commits, {pct}%)*"
            )
    else:
        out.append("- _(Not enough multi-file commit history yet to surface high-confidence hidden couplings.)_")

    return "\n".join(out).rstrip() + "\n"


def discover_domain_dossiers() -> List[Tuple[str, str, str]]:
    entries: List[Tuple[str, str, str]] = []
    if not DOMAINS_DIR.exists():
        return entries
    paths_re = re.compile(r"^>\s*\*\*Paths:\*\*\s*`?([^`\n]+)`?", re.IGNORECASE)
    summary_re = re.compile(r"^>\s*\*\*Summary:\*\*\s*(.+)$", re.IGNORECASE)
    title_re = re.compile(r"^#\s+(.+)$")
    for p in sorted(DOMAINS_DIR.glob("*.md")):
        title, paths_pat, summary = p.stem, "", ""
        for ln in p.read_text(encoding="utf-8", errors="replace").splitlines()[:15]:
            s = ln.strip()
            mt = title_re.match(s)
            if mt and title == p.stem:
                title = mt.group(1).replace("Domain Dossier:", "").strip()
            mp = paths_re.match(s)
            if mp:
                paths_pat = mp.group(1).strip()
            ms = summary_re.match(s)
            if ms:
                summary = ms.group(1).strip()
        entries.append((rel(p), paths_pat, summary or title))
    return entries


def build_system_map(cfg: Dict[str, Any]) -> str:
    proj = cfg.get("project_name", ROOT.name)
    quarantined = cfg.get("quarantined_paths", [])
    dossiers = discover_domain_dossiers()

    out = [
        f"# {proj} — System Map & Self-Evolving Context Index (`pak v2.0`)",
        "",
        "> Auto-generated incrementally via `.pak/index.sqlite` by `scripts/pak/build_atlas.py`.",
        "> Consult `docs/atlas/*` before creating new functions and `docs/domains/*` before editing business logic.",
        "",
        "## 1. Atlas & Intelligence Files",
        "- `docs/atlas/01_CODE_CAPABILITIES.md` — Exported functions, classes, interfaces, hooks, and components.",
        "- `docs/atlas/02_DATA_CONTRACTS.md` — HTTP routes, SQL schemas/queries, Protobuf/GraphQL/Prisma contracts.",
        "- `docs/atlas/03_UI_AND_ASSETS.md` — CSS design tokens, semantic classes, themes, and i18n locale summary.",
        "- `docs/atlas/04_DEPENDENCY_GRAPH.md` — Module dependency & reverse-dependent blast-radius graph (`<-`).",
        "- `docs/atlas/05_COCHANGE_AND_CONTRACTS.md` — Event-bus pub/sub topics, microservice links & `git log` hidden co-changes.",
        "- `docs/atlas/contracts.json` — Machine-readable microservice contract manifest for cross-repo federation.",
        "",
        "## 2. Quarantined Dead / Legacy Paths (DO NOT READ AS TRUTH OR EDIT)",
    ]
    if quarantined:
        for q in quarantined:
            out.append(f"- `{q}`")
    else:
        out.append("- _(None configured — add obsolete prototype folders to `quarantined_paths` in `pak.config.json`.)_")

    out.append("\n## 3. Dynamic Domain Dossier Routing Table (`docs/domains/`)")
    out.append("_(Auto-discovered from `docs/domains/*.md` — add `> **Paths:**` & `> **Summary:**` headers to register new domains automatically)_")
    if dossiers:
        for d_path, pat, summary in dossiers:
            suffix = f" *(matches: `{pat}`)*" if pat else ""
            out.append(f"- `{d_path}` — {summary}{suffix}")
    else:
        out.append("- _(Run the `pak-bootstrap` skill to audit the codebase and generate domain dossiers.)_")

    return "\n".join(out) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Build pak v2.0 incremental SQLite Atlas & Dependency Graph")
    parser.add_argument("--quiet", action="store_true", help="Suppress summary output")
    args = parser.parse_args()

    cfg = load_config()
    ATLAS_DIR.mkdir(parents=True, exist_ok=True)

    conn, has_fts = init_db()
    total_files, updated_files = sync_incremental_index(conn, has_fts, cfg)
    dep_md, direct_pairs = render_dependency_graph(conn)
    cochanges = mine_git_cochanges(cfg, direct_pairs)
    cochange_md = export_contracts_and_cochange(conn, cfg, cochanges)

    files = {
        "00_SYSTEM_MAP.md": build_system_map(cfg),
        "01_CODE_CAPABILITIES.md": render_code_capabilities(conn),
        "02_DATA_CONTRACTS.md": render_data_contracts(conn),
        "03_UI_AND_ASSETS.md": render_ui_and_i18n(conn, cfg),
        "04_DEPENDENCY_GRAPH.md": dep_md,
        "05_COCHANGE_AND_CONTRACTS.md": cochange_md,
    }
    conn.close()

    for name, content in files.items():
        target = ATLAS_DIR / name
        old = target.read_text(encoding="utf-8") if target.exists() else None
        if old != content:
            target.write_text(content, encoding="utf-8")

    if not args.quiet:
        print(
            f"[pak] Indexed {total_files} files ({updated_files} re-parsed incrementally via SQLite) -> {len(files)} Atlas files in docs/atlas/"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
