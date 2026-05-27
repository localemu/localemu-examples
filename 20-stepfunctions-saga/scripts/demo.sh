#!/usr/bin/env bash
# End-to-end orchestrator: setup, happy path, fault-injection matrix.
# Re-runnable: step 01 clears prior state before provisioning.

set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${HERE}/infra/01_setup.sh"
"${HERE}/infra/02_happy_path.sh"
"${HERE}/infra/03_fault_inject.sh"

echo
echo "→ demo complete. Run scripts/teardown.sh when done."
