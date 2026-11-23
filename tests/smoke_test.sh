#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# pak Automated Smoke & Cross-Vendor Compatibility Test Suite
# Tests greenfield + brownfield installation, non-destructive rule merging,
# polyglot Atlas generation, blast-radius tracing, and AGY + Claude + Git hooks.
# ==============================================================================

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BASE="$(mktemp -d)"
trap 'rm -rf "$TMP_BASE"' EXIT

echo "==> [1/6] Testing non-interactive install into simulated polyglot repo (all agents + hooks)..."
PROJ="$TMP_BASE/sample-app"
mkdir -p "$PROJ/internal/service" "$PROJ/proto" "$PROJ/web/src/locales"
(
    cd "$PROJ"
    git init -q
    echo "# Existing Project Rules" > AGENTS.md
    echo "Keep existing custom rule." >> AGENTS.md
    cat > internal/service/billing.go << 'EOF'
package service

type InvoiceService interface {
	CalculateTotal(cents int64) int64
}

func FormatCurrency(cents int64) string { return "$0.00" }
EOF
    cat > proto/billing.proto << 'EOF'
syntax = "proto3";
service BillingService {
  rpc CreateInvoice(CreateInvoiceReq) returns (CreateInvoiceResp);
}
message CreateInvoiceReq {}
message CreateInvoiceResp {}
EOF
    echo '{"app.title": "Hello", "app.save": "Save"}' > web/src/locales/en.json
    echo '{"app.title": "Salut", "app.save": "Salvează"}' > web/src/locales/ro.json
    git add .
    git -c user.name="Test" -c user.email="test@example.com" commit -q -m "init"
)

python3 "$KIT_DIR/pak" init "$PROJ" --yes --agents all --stage existing --hooks both --uuid-v7 --i18n-dir "web/src/locales"

echo "==> [2/6] Verifying generated multi-vendor files & non-destructive merge..."
grep -q "Keep existing custom rule." "$PROJ/AGENTS.md"
grep -q "PAK:START" "$PROJ/AGENTS.md"
test -f "$PROJ/GEMINI.md"
test -f "$PROJ/CLAUDE.md"
test -f "$PROJ/.agents/hooks.json"
test -f "$PROJ/.claude/settings.json"
test -x "$PROJ/.git/hooks/pre-commit"
test -f "$PROJ/.agents/skills/pak-atlas/agents/openai.yaml"
test -L "$PROJ/.claude/skills/pak-atlas" || test -d "$PROJ/.claude/skills/pak-atlas"
grep -q "CalculateTotal" "$PROJ/docs/atlas/01_CODE_CAPABILITIES.md"
grep -q "BillingService.CreateInvoice" "$PROJ/docs/atlas/02_DATA_CONTRACTS.md"

echo "==> [3/6] Verifying 'pak trace' and clean 'pak check'..."
python3 "$KIT_DIR/pak" trace "CalculateTotal" "$PROJ" | grep -q "billing.go"
python3 "$KIT_DIR/pak" check "$PROJ" | grep -q "OK"

# Commit pak setup so working tree is clean, then test hook pass-through
(
    cd "$PROJ"
    git add .
    git -c user.name="Test" -c user.email="test@example.com" commit -q -m "add pak"
)

AGY_CLEAN="$(echo '{"terminationReason":"NO_TOOL_CALL","continuationActive":false}' | bash "$PROJ/scripts/pak/verify_impact.sh" --agy-hook)"
[ "$AGY_CLEAN" = '{"decision": "allow"}' ]

CLAUDE_CLEAN="$(echo '{"stop_hook_active":false}' | bash "$PROJ/scripts/pak/verify_impact.sh" --claude-hook)"
[ "$CLAUDE_CLEAN" = '{}' ]

echo "==> [4/6] Verifying violation blocking (i18n drift + UUIDv4 + Proto codegen drift)..."
echo '{"app.title": "Salut"}' > "$PROJ/web/src/locales/ro.json"
echo '// edit' >> "$PROJ/proto/billing.proto"
cat >> "$PROJ/internal/service/billing.go" << 'EOF'
func BadID() string { return uuid.NewString() }
EOF

AGY_BLOCK="$(echo '{"terminationReason":"NO_TOOL_CALL","continuationActive":false}' | bash "$PROJ/scripts/pak/verify_impact.sh" --agy-hook)"
echo "$AGY_BLOCK" | grep -q '"decision": "continue"'
echo "$AGY_BLOCK" | grep -q "i18n parity check failed"
echo "$AGY_BLOCK" | grep -q "Protobuf drift"
echo "$AGY_BLOCK" | grep -q "UUIDv4 call detected"

CLAUDE_BLOCK="$(echo '{"stop_hook_active":false}' | bash "$PROJ/scripts/pak/verify_impact.sh" --claude-hook)"
echo "$CLAUDE_BLOCK" | grep -q '"decision": "block"'

# Verify loop-prevention flags allow immediate stop even when dirty
AGY_LOOP_GUARD="$(echo '{"terminationReason":"NO_TOOL_CALL","continuationActive":true}' | bash "$PROJ/scripts/pak/verify_impact.sh" --agy-hook)"
[ "$AGY_LOOP_GUARD" = '{"decision": "allow"}' ]

CLAUDE_LOOP_GUARD="$(echo '{"stop_hook_active":true}' | bash "$PROJ/scripts/pak/verify_impact.sh" --claude-hook)"
[ "$CLAUDE_LOOP_GUARD" = '{}' ]

echo "==> [5/6] Verifying self-evolving dependency graph, dynamic new-domain routing & structural evolution gate..."
(
    cd "$PROJ"
    git checkout -- .
    mkdir -p internal/payments
    cat > internal/payments/stripe.go << 'EOF'
package payments

func ChargeCard() error { return nil }
EOF
)
# Structural evolution (new Go module added without docs/domains/ update) must trigger Stop gate once:
EVO_BLOCK="$(echo '{"terminationReason":"NO_TOOL_CALL","continuationActive":false}' | bash "$PROJ/scripts/pak/verify_impact.sh" --agy-hook)"
echo "$EVO_BLOCK" | grep -q "Structural/dependency evolution detected"

# Adding a self-routing domain dossier satisfies the gate AND auto-registers in 00_SYSTEM_MAP.md & blast_radius.sh:
cat > "$PROJ/docs/domains/payments.md" << 'EOF'
# Domain Dossier: Payments

> **Paths:** `internal/payments/`
> **Summary:** Card charging and Stripe webhook idempotency.
EOF

EVO_PASS="$(echo '{"terminationReason":"NO_TOOL_CALL","continuationActive":false}' | bash "$PROJ/scripts/pak/verify_impact.sh" --agy-hook)"
[ "$EVO_PASS" = '{"decision": "allow"}' ]
test -f "$PROJ/docs/atlas/04_DEPENDENCY_GRAPH.md"
grep -q "docs/domains/payments.md" "$PROJ/docs/atlas/00_SYSTEM_MAP.md"
python3 "$KIT_DIR/pak" trace "ChargeCard" "$PROJ" | grep -q "docs/domains/payments.md"

echo "==> [6/6] Verifying clean 'pak uninstall'..."
python3 "$KIT_DIR/pak" uninstall "$PROJ"
grep -q "Keep existing custom rule." "$PROJ/AGENTS.md"
! grep -q "PAK:START" "$PROJ/AGENTS.md"

echo "==> ALL SMOKE TESTS PASSED!"
