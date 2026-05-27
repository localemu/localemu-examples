#!/usr/bin/env bash
# End-to-end orchestrator: build the network + compute + service planes,
# then run the 10-assertion connectivity matrix. Re-runnable.
#
# Requires: LocalEmu started with EC2_VM_MANAGER=docker
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${HERE}/infra/01_network.sh"
"${HERE}/infra/02_compute.sh"
"${HERE}/infra/03_service.sh"
"${HERE}/infra/04_connectivity.sh"

echo
echo "→ demo complete. Run scripts/teardown.sh when done."
