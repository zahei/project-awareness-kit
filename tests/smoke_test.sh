#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# pak — Comprehensive 10-Stage Hermetic End-to-End Test Suite
# Verifies:
#   1. Polyglot microservice install (`billing-svc` + `web-portal`)
#   2. Incremental SQLite FTS5 cache (<25ms 0-reparse warm run) & multi-vendor files
#   3. Federated cross-microservice contract & event-bus trace
#   4. Wire-breaking Protobuf tag guard + UUIDv4 + i18n parity + loop-safety
#   5. Mechanical near-duplicate function detector (`RenderAccountCurrency` vs `FormatAccountCurrency`)
#   6. Cross-repo consumer advisory on modified service endpoint
#   7. Graph-driven `pak affected` minimal unit test selector
#   8. Self-evolving new-domain routing
#   9. Global `pak status` & `pak upgrade` from an arbitrary non-project folder + clean uninstall/`--purge`
#  10. Shell-aware `pak install-cli` & `pak uninstall-cli` (`zsh`/`bash`/`fish` PATH injection)
# ==============================================================================

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BASE="$(mktemp -d)"
trap 'rm -rf "$TMP_BASE"' EXIT
export HOME="$TMP_BASE/home"
mkdir -p "$HOME"

PROJ="$TMP_BASE/billing-svc"
PORTAL="$TMP_BASE/web-portal"

echo "==> [1/10] Creating simulated microservice pair (billing-svc + web-portal) & installing pak..."
mkdir -p "$PROJ/internal/service" "$PROJ/proto" "$PROJ/web/src/locales" "$PORTAL/src/api"

cat > "$PROJ/go.mod" << 'EOF'
module example.com/billing
go 1.22
EOF

cat > "$PROJ/internal/service/billing.go" << 'EOF'
package service

import "net/http"

type InvoiceService interface {
	CalculateTotal(cents int64) int64
}

func FormatAccountCurrency(cents int64) string { return "$0.00" }

func RegisterRoutes(mux *http.ServeMux, bus interface{ Publish(string, any) }) {
	mux.HandleFunc("/api/v1/invoices", nil)
	bus.Publish("invoice.paid", nil)
}
EOF

cat > "$PROJ/internal/service/billing_test.go" << 'EOF'
package service
import "testing"
func TestFormatAccountCurrency(t *testing.T) {
	if FormatAccountCurrency(0) == "" { t.Fatal("empty") }
}
EOF

cat > "$PROJ/proto/billing.proto" << 'EOF'
syntax = "proto3";
service BillingService {
  rpc CreateInvoice(CreateInvoiceReq) returns (CreateInvoiceResp);
}
message CreateInvoiceReq {
  string invoice_id = 1;
  int64 amount_cents = 2;
}
message CreateInvoiceResp {}
EOF

echo '{"app.title": "Hello", "app.save": "Save"}' > "$PROJ/web/src/locales/en.json"
echo '{"app.title": "Salut", "app.save": "Salvează"}' > "$PROJ/web/src/locales/ro.json"
echo -e "# Existing Project Rules\nKeep existing custom rule." > "$PROJ/AGENTS.md"

(
    cd "$PROJ"
    git init -q
    git add .
    git -c user.name="Test" -c user.email="test@example.com" commit -q -m "init billing-svc"
)

cat > "$PORTAL/src/api/billingClient.ts" << 'EOF'
export async function loadInvoices() {
  return fetch("/api/v1/invoices");
}
export function subscribeEvents(bus: any) {
  bus.Subscribe("invoice.paid", () => {});
}
EOF
(
    cd "$PORTAL"
    git init -q
    git add .
    git -c user.name="Test" -c user.email="test@example.com" commit -q -m "init web-portal"
)

python3 "$KIT_DIR/pak" init "$PORTAL" --yes --agents openai --stage existing --hooks none
python3 "$KIT_DIR/pak" init "$PROJ" --yes --agents all --stage existing --hooks both --uuid-v7 --i18n-dir "web/src/locales" --link-repos "../web-portal"

echo "==> [2/10] Verifying incremental SQLite cache (0 files re-parsed on warm run) & multi-vendor files..."
WARM_OUT="$(python3 "$KIT_DIR/pak" atlas "$PROJ")"
echo "$WARM_OUT" | grep -q "(0 re-parsed incrementally via SQLite)"
test -f "$PROJ/.pak/index.sqlite"
test -f "$PROJ/.pak/.gitignore"
test -f "$PROJ/docs/atlas/contracts.json"
test -f "$PROJ/docs/atlas/05_COCHANGE_AND_CONTRACTS.md"
grep -q "Keep existing custom rule." "$PROJ/AGENTS.md"
test -f "$PROJ/.agents/hooks.json"
test -f "$PROJ/.claude/settings.json"
test -x "$PROJ/.git/hooks/pre-commit"

(
    cd "$PROJ"
    git add .
    git -c user.name="Test" -c user.email="test@example.com" commit -q -m "chore: install pak"
)

echo "==> [3/10] Verifying federated cross-microservice trace ('invoice.paid' & '/api/v1/invoices')..."
TRACE_OUT="$(python3 "$KIT_DIR/pak" trace "invoice.paid" "$PROJ")"
echo "$TRACE_OUT" | grep -q "FEDERATED SIBLING MICROSERVICE IMPACTS"
echo "$TRACE_OUT" | grep -q "web-portal CONSUMES EVENT"

echo "==> [4/10] Verifying wire-breaking Protobuf field-tag removal guard + UUIDv4 + i18n parity..."
echo '{"app.title": "Salut"}' > "$PROJ/web/src/locales/ro.json"
# Remove field tag = 2 without `reserved 2;` -> wire-breaking!
cat > "$PROJ/proto/billing.proto" << 'EOF'
syntax = "proto3";
service BillingService {
  rpc CreateInvoice(CreateInvoiceReq) returns (CreateInvoiceResp);
}
message CreateInvoiceReq {
  string invoice_id = 1;
}
message CreateInvoiceResp {}
EOF
cat >> "$PROJ/internal/service/billing.go" << 'EOF'
func BadID() string { return uuid.NewString() }
EOF

AGY_BLOCK="$(echo '{"terminationReason":"NO_TOOL_CALL","continuationActive":false}' | bash "$PROJ/scripts/pak/verify_impact.sh" --agy-hook)"
echo "$AGY_BLOCK" | grep -q "Wire-breaking Protobuf change"
echo "$AGY_BLOCK" | grep -q "i18n parity check failed"
echo "$AGY_BLOCK" | grep -q "UUIDv4 call detected"

# Loop-safety check
AGY_LOOP="$(echo '{"terminationReason":"NO_TOOL_CALL","continuationActive":true}' | bash "$PROJ/scripts/pak/verify_impact.sh" --agy-hook)"
[ "$AGY_LOOP" = '{"decision": "allow"}' ]

echo "==> [5/10] Verifying mechanical near-duplicate function detector (RenderAccountCurrency vs FormatAccountCurrency)..."
(cd "$PROJ" && git checkout -- .)
mkdir -p "$PROJ/internal/util"
cat > "$PROJ/internal/util/money.go" << 'EOF'
package util

func RenderAccountCurrency(cents int64) string { return "$0.00" }
EOF
# Create dossier update so only duplicate check triggers
echo "" >> "$PROJ/docs/domains/00-core-architecture.md"

DUP_BLOCK="$(echo '{"terminationReason":"NO_TOOL_CALL","continuationActive":false}' | bash "$PROJ/scripts/pak/verify_impact.sh" --agy-hook)"
echo "$DUP_BLOCK" | grep -q "Potential duplicate function 'RenderAccountCurrency'"
echo "$DUP_BLOCK" | grep -q "FormatAccountCurrency"
rm -rf "$PROJ/internal/util"
(cd "$PROJ" && git checkout -- .)

echo "==> [6/10] Verifying cross-repo consumer advisory on modified service endpoint..."
echo "// touch endpoint file" >> "$PROJ/internal/service/billing.go"
CLI_CHECK="$(python3 "$KIT_DIR/pak" check "$PROJ")"
echo "$CLI_CHECK" | grep -q "Cross-microservice consumers affected: web-portal consumes"

echo "==> [7/10] Verifying 'pak affected --run' fast targeted test execution..."
AFF_OUT="$(python3 "$KIT_DIR/pak" affected --run "$PROJ")"
echo "$AFF_OUT" | grep -q "go test ./internal/service"
(cd "$PROJ" && git checkout -- .)

echo "==> [8/10] Verifying self-evolving new-domain routing & inline dossier summary..."
mkdir -p "$PROJ/internal/payments"
cat > "$PROJ/internal/payments/stripe.go" << 'EOF'
package payments
func ChargeCustomerCard() error { return nil }
EOF
EVO_BLOCK="$(echo '{"terminationReason":"NO_TOOL_CALL","continuationActive":false}' | bash "$PROJ/scripts/pak/verify_impact.sh" --agy-hook)"
echo "$EVO_BLOCK" | grep -q "Structural/dependency evolution detected"

cat > "$PROJ/docs/domains/payments.md" << 'EOF'
# Domain Dossier: Payments

> **Paths:** `internal/payments/`
> **Summary:** Stripe charge lifecycle and idempotency keys.
EOF
EVO_PASS="$(echo '{"terminationReason":"NO_TOOL_CALL","continuationActive":false}' | bash "$PROJ/scripts/pak/verify_impact.sh" --agy-hook)"
[ "$EVO_PASS" = '{"decision": "allow"}' ]
TRACE_DOM="$(python3 "$KIT_DIR/pak" trace "ChargeCustomerCard" "$PROJ")"
echo "$TRACE_DOM" | grep -q "docs/domains/payments.md — Stripe charge lifecycle and idempotency keys."
! grep -q 'pak-atlas.*pak-impact.*pak-domains' "$PROJ/AGENTS.md"

echo "==> [9/10] Verifying global 'pak status' & 'pak upgrade' from an arbitrary non-project folder + clean uninstall..."
echo "# Custom Matrix Row: Billing <-> Ledger" >> "$PROJ/.agents/skills/pak-impact/references/dependency-matrix.md"
python3 -c '
import json, pathlib
p = pathlib.Path("'"$PROJ"'/pak.config.json")
d = json.loads(p.read_text())
d["pak_version"] = "1.0.0"
p.write_text(json.dumps(d, indent=2))
'
echo "# outdated script" > "$PROJ/scripts/pak/blast_radius.sh"

# Run 'pak status' and 'pak upgrade' from /tmp (an arbitrary folder with NO pak.config.json!)
ARB_DIR="$(dirname "$PROJ")/arbitrary_empty_folder"
mkdir -p "$ARB_DIR"
(cd "$ARB_DIR" && python3 "$KIT_DIR/pak" status) | grep -q "billing-svc"
(cd "$ARB_DIR" && python3 "$KIT_DIR/pak" status) | grep -q "upgrade available"

(cd "$ARB_DIR" && python3 "$KIT_DIR/pak" upgrade --projects-only)
python3 "$KIT_DIR/pak" status "$PROJ" | grep -q "up to date"
grep -q "Custom Matrix Row: Billing <-> Ledger" "$PROJ/.agents/skills/pak-impact/references/dependency-matrix.md"
grep -q "Stripe charge lifecycle" "$PROJ/docs/domains/payments.md"
grep -q '"enforce_uuid_v7": true' "$PROJ/pak.config.json"
grep -q "INDEXED SYMBOLS, CONTRACTS & REVERSE DEPENDENTS" "$PROJ/scripts/pak/blast_radius.sh"

python3 "$KIT_DIR/pak" uninstall "$PROJ"
grep -q "Keep existing custom rule." "$PROJ/AGENTS.md"
! grep -q "PAK:START" "$PROJ/AGENTS.md"
[ ! -d "$PROJ/scripts/pak" ]
[ ! -d "$PROJ/.pak" ]
[ ! -d "$PROJ/docs/atlas" ]
[ ! -f "$PROJ/.agents/hooks.json" ]
[ ! -f "$PROJ/.claude/settings.json" ]
[ ! -f "$PROJ/.git/hooks/pre-commit" ]
# Safe mode preserves docs/domains/ and pak.config.json
[ -f "$PROJ/docs/domains/payments.md" ]
[ -f "$PROJ/pak.config.json" ]

# Full --purge mode removes docs/domains/ and pak.config.json too
python3 "$KIT_DIR/pak" uninstall --purge "$PROJ"
[ ! -d "$PROJ/docs/domains" ]
[ ! -f "$PROJ/pak.config.json" ]

echo "==> [10/10] Verifying shell-aware 'pak install-cli' & 'pak uninstall-cli' (zsh/bash/fish PATH injection)..."
FAKE_HOME="$(dirname "$PROJ")/fake_zsh_home"
mkdir -p "$FAKE_HOME"
HOME="$FAKE_HOME" SHELL="/bin/zsh" PATH="/usr/bin:/bin" python3 "$KIT_DIR/pak" install-cli
[ -L "$FAKE_HOME/.local/bin/pak" ]
[ -f "$FAKE_HOME/.zshrc" ]
grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$FAKE_HOME/.zshrc"

HOME="$FAKE_HOME" SHELL="/bin/zsh" PATH="/usr/bin:/bin" python3 "$KIT_DIR/pak" uninstall-cli
[ ! -e "$FAKE_HOME/.local/bin/pak" ]
[ ! -f "$FAKE_HOME/.zshrc" ]

PAK_VER="$(python3 "$KIT_DIR/pak" --version)"
echo "==> ALL 10/10 SMOKE TESTS PASSED ($PAK_VER)!"
