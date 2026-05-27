#!/usr/bin/env bash
# End-to-end orchestrator: setup, baseline, mutation loop.
# Re-runnable: step 01 clears prior state before provisioning.
#
# Requires: LocalEmu started with IAM_ENFORCEMENT=1
#   IAM_ENFORCEMENT=1 localemu start

set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${HERE}/infra/01_setup.sh"
"${HERE}/infra/02_baseline.sh"
"${HERE}/infra/03_mutate.sh"

echo
echo "→ demo complete. Run scripts/teardown.sh when done."
