# Domain Dossier: Core Architecture & Conventions

> **Paths:** `src/|internal/|cmd/|app/|pkg/`
> **Summary:** Primary entrypoints, domain invariants, transaction boundaries, and cross-module conventions.

## 1. Core Workflows & Entrypoints
- Document primary request/command lifecycles, background jobs, and transaction boundaries here.

## 2. Domain Invariants & Formulas
- Record non-obvious business rules, units/currencies/timezones, idempotency keys, and security boundaries here.

## 3. Corner Cases & Regression Traps
- Record subtle edge cases, race conditions, and historical bug postmortems that future changes must preserve.

## 4. Cross-Module Impact Checklist
- List downstream consumers (workers, caches, notifications, UI views, codegen) that must be checked when modifying this domain.
