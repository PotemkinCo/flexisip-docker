#!/usr/bin/env bash
set -euo pipefail

# Keep crash dumps outside the container writable layer. The compose file
# supplies a bounded RLIMIT_CORE and proxy_data is a persistent volume.
CORE_DIR=/var/opt/belledonne-communications/cores
mkdir -p "$CORE_DIR"
cd "$CORE_DIR"

exec "$@"
