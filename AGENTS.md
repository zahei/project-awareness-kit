# `project-awareness-kit` (`pak`) — Workspace Agent Rules

## Communication & Git Workflow
- **Always communicate in English.**
- **Commit and Push Every Time:** After completing and verifying any change (`bash tests/smoke_test.sh`), stage, `git commit`, and `git push origin main`.

## Core Engineering Constraints
1. **Zero External Dependencies:** Everything in `pak` and `templates/scripts/pak/*` MUST run on Python 3.9+ standard library (`sqlite3` + `FTS5`, `re`, `json`, `subprocess`, `pathlib`) + `bash` + `git`. Never introduce `pip`, `npm`, or daemon requirements.
2. **Sub-Second & Token-Frugal:** Keep incremental warm checks `<50ms`, full cold checks `<300ms`, and `Stop` hooks silent (`0` extra LLM turns) whenever checks pass.
3. **Version & Documentation Sync:** Whenever bumping `PAK_VERSION` in `pak`, always update in the same commit:
   - `pak` (`PAK_VERSION`)
   - `templates/pak.config.default.json` (`pak_version`)
   - `examples/pak.config.fullstack.json` (`pak_version`)
   - `README.md` (title version & any new CLI/config options)
4. **Non-Destructive Upgrade & Uninstall Guarantees:** `pak upgrade` must strictly preserve project-owned `pak.config.json` rules, `docs/domains/*.md`, and `.agents/skills/pak-impact/references/dependency-matrix.md`. `pak uninstall` must strip all `<!-- PAK:START -->` / `# --- PAK:START ---` blocks and hooks cleanly.
5. **Mandatory Verification:** Always run `bash tests/smoke_test.sh` before committing.
