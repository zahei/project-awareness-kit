#!/usr/bin/env python3
"""
pak v2.0 — Graph-Driven "Affected-Only" Fast Test Selector (`scripts/pak/affected_tests.py`).
Uses `.pak/index.sqlite` reverse-dependent edges + `git diff` to compute (and optionally run)
ONLY the unit test packages/files impacted by your current changes — keeping verification
in 1–3 seconds instead of running 30-minute full CI test suites.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path
from typing import List, Set

ROOT = Path(__file__).resolve().parents[2]
DB_PATH = ROOT / ".pak" / "index.sqlite"


def get_changed_files() -> List[str]:
    proc = subprocess.run(
        ["git", "status", "--porcelain", "-uall"],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    changed = [
        ln[3:].strip().split(" -> ")[-1]
        for ln in proc.stdout.splitlines()
        if len(ln) > 3
    ]
    if not changed:
        # Fallback to last commit diff if working tree is already clean
        proc2 = subprocess.run(
            ["git", "diff", "--name-only", "HEAD~1", "HEAD"],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
        changed = [ln.strip() for ln in proc2.stdout.splitlines() if ln.strip()]
    return changed


def compute_affected_commands(changed: List[str]) -> List[str]:
    if not changed:
        return []

    if not DB_PATH.exists():
        atlas_py = ROOT / "scripts" / "pak" / "build_atlas.py"
        if atlas_py.exists():
            subprocess.run([sys.executable, str(atlas_py), "--quiet"], cwd=str(ROOT), check=False)

    conn = sqlite3.connect(str(DB_PATH)) if DB_PATH.exists() else None

    # 1. Go Affected Packages (changed package + direct reverse dependents with *_test.go)
    go_pkgs: Set[str] = set()
    for f in changed:
        if f.endswith(".go"):
            pkg = Path(f).parent.as_posix()
            go_pkgs.add("." if pkg == "." else pkg)

    if conn and go_pkgs:
        frontier = set(go_pkgs)
        for _ in range(2):  # 2-hop reverse dependent propagation
            next_hop: Set[str] = set()
            for pkg in frontier:
                rows = conn.execute(
                    "SELECT DISTINCT src_path FROM imports WHERE lang = 'go' AND dst_target = ?",
                    (pkg,),
                ).fetchall()
                for (imp_pkg,) in rows:
                    if imp_pkg not in go_pkgs:
                        next_hop.add(imp_pkg)
            go_pkgs |= next_hop
            frontier = next_hop
            if not frontier:
                break

    Testable_go_pkgs = sorted(
        f"./{p}" if p != "." else "."
        for p in go_pkgs
        if (ROOT / p).is_dir() and list((ROOT / p).glob("*_test.go"))
    )

    # 2. Frontend TS/JS Affected Test Files
    ts_changed: Set[str] = {
        f for f in changed if Path(f).suffix in (".ts", ".tsx", ".js", ".jsx")
    }
    if conn and ts_changed:
        frontier_ts = set(ts_changed)
        for _ in range(2):
            next_ts: Set[str] = set()
            for mod in frontier_ts:
                for (imp_src,) in conn.execute(
                    "SELECT DISTINCT src_path FROM imports WHERE lang = 'ts' AND dst_target = ?",
                    (mod,),
                ):
                    if imp_src not in ts_changed:
                        next_ts.add(imp_src)
            ts_changed |= next_ts
            frontier_ts = next_ts
            if not frontier_ts:
                break

    ts_test_files: Set[str] = set()
    stems = {Path(f).stem.replace(".test", "").replace(".spec", "") for f in ts_changed}
    for test_cand in list(ROOT.glob("web/src/**/*.{test,spec}.{ts,tsx,js,jsx}")) + list(
        ROOT.glob("src/**/*.{test,spec}.{ts,tsx,js,jsx}")
    ):
        pass
    # Explicit glob expansion for Python pathlib (brace expansion not supported in pathlib.glob)
    for root_sub in ("web/src", "src", "tests"):
        base = ROOT / root_sub
        if not base.exists():
            continue
        for p in base.rglob("*"):
            if not p.is_file():
                continue
            if any(p.name.endswith(suf) for suf in (".test.ts", ".test.tsx", ".spec.ts", ".spec.tsx", ".test.js", ".spec.js")):
                r = p.relative_to(ROOT).as_posix()
                base_stem = p.name.split(".")[0]
                if r in ts_changed or base_stem in stems:
                    ts_test_files.add(r)
                else:
                    txt = p.read_text(encoding="utf-8", errors="replace")
                    if any(s and len(s) >= 4 and s in txt for s in stems):
                        ts_test_files.add(r)

    # 3. Python Affected Test Files
    py_changed = {f for f in changed if f.endswith(".py")}
    py_test_files: Set[str] = set()
    if py_changed:
        py_stems = {Path(f).stem.removeprefix("test_").removesuffix("_test") for f in py_changed}
        for p in ROOT.rglob("*.py"):
            r = p.relative_to(ROOT).as_posix()
            if any(part in r.split("/") for part in (".venv", "venv", "node_modules", ".pak")):
                continue
            if p.name.startswith("test_") or p.name.endswith("_test.py"):
                s = p.stem.removeprefix("test_").removesuffix("_test")
                if r in py_changed or s in py_stems:
                    py_test_files.add(r)

    if conn:
        conn.close()

    commands: List[str] = []
    if Testable_go_pkgs:
        commands.append("go test " + " ".join(Testable_go_pkgs))
    if ts_test_files:
        if (ROOT / "web" / "package.json").exists():
            rel_to_web = [f.removeprefix("web/") for f in sorted(ts_test_files) if f.startswith("web/")]
            if rel_to_web:
                commands.append("npm --prefix web test -- --run " + " ".join(rel_to_web))
        elif (ROOT / "package.json").exists():
            commands.append("npx vitest run " + " ".join(sorted(ts_test_files)))
    if py_test_files:
        commands.append("pytest " + " ".join(sorted(py_test_files)))

    return commands


def main() -> int:
    parser = argparse.ArgumentParser(description="Compute or run affected-only fast unit tests")
    parser.add_argument("--run", action="store_true", help="Execute the affected test commands immediately")
    args = parser.parse_args()

    changed = get_changed_files()
    cmds = compute_affected_commands(changed)
    if not cmds:
        print("[pak:affected] No impacted unit test targets detected for current diff.")
        return 0

    print("[pak:affected] Minimal impacted test commands:")
    for c in cmds:
        print(f"  $ {c}")

    if args.run:
        env = os.environ.copy()
        if "/usr/local/go/bin" not in env.get("PATH", "") and Path("/usr/local/go/bin").is_dir():
            env["PATH"] = f"/usr/local/go/bin:{env.get('PATH', '')}"
        for c in cmds:
            exe = c.split()[0]
            if not shutil.which(exe, path=env.get("PATH")):
                print(f"[pak:affected] Skipping live run of '{c}' ('{exe}' binary not installed on host PATH).")
                continue
            print(f"\n==> Running: {c}")
            rc = subprocess.run(["bash", "-c", c], cwd=str(ROOT), env=env, check=False).returncode
            if rc != 0:
                return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())
