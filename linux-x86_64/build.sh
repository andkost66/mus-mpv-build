#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible entry point; implementation lives in the shared pipeline.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec "$SCRIPT_DIR/../scripts/build-package-verify.sh" linux-x86_64
