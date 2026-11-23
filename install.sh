#!/usr/bin/env bash
set -euo pipefail

# Convenience wrapper around `./pak init`
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$KIT_DIR/pak" init "$@"
