#!/usr/bin/env bash
set -euo pipefail

if [[ "${ENABLE_EKT_SERVER:-false}" == "true" ]]; then
  echo "[entrypoint] WARNING: ENABLE_EKT_SERVER=true is set, but it is ignored on the proxy. The conference service controls E2EE." >&2
fi

# Keep crash dumps outside the container writable layer. The compose file
# supplies a bounded RLIMIT_CORE and proxy_data is a persistent volume.
CORE_DIR=/var/opt/belledonne-communications/cores
mkdir -p "$CORE_DIR"
cd "$CORE_DIR"

exec "$@"
