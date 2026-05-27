#!/usr/bin/env bash
# End-to-end orchestrator: provision, run the load test against the
# CURRENTLY configured chaos profile, report.
#
# To see different scenarios, restart LocalEmu with different env
# vars between runs (see README.md "Chaos matrix").

set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${HERE}/infra/01_setup.sh"
"${HERE}/infra/02_load_test.sh"

echo
echo "→ demo complete. Run scripts/teardown.sh when done."
