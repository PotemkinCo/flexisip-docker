#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root_dir"

command -v jq >/dev/null || { echo 'error: jq is required' >&2; exit 1; }

jq -e 'type == "object" and .flexisip and .["flexisip-conference"]' state/built.json >/dev/null

for key in FLEXISIP_VERSION FLEXISIP_CONFERENCE_VERSION FLEXISIP_PROXY_DIGEST FLEXISIP_CONFERENCE_DIGEST; do
  grep -Eq "^${key}=[^[:space:]]+$" production.env || {
    echo "error: missing or empty ${key} in production.env" >&2
    exit 1
  }
done
grep -Eq '^FLEXISIP_PROXY_DIGEST=sha256:[0-9a-f]{64}$' production.env
grep -Eq '^FLEXISIP_CONFERENCE_DIGEST=sha256:[0-9a-f]{64}$' production.env

if grep -R -n -E 'type=raw,value=latest|ghcr\.io/[^[:space:]]+:latest([[:space:]"`]|$)' \
    .github README.md AGENTS.md docker-compose.yml; then
  echo 'error: mutable latest image references remain' >&2
  exit 1
fi
if grep -R -n -E 'build-debs|softprops/action-gh-release|CPACK_GENERATOR=DEB' .github/workflows; then
  echo 'error: .deb build/release workflow remains' >&2
  exit 1
fi
if grep -n -E 'ENABLE_EKT_SERVER' .env.example docker-compose.yml docker/proxy/entrypoint.sh docker/conference/entrypoint.sh config/flexisip-conference.conf; then
  echo 'error: obsolete runtime ENABLE_EKT_SERVER flag remains' >&2
  exit 1
fi
if grep -n -E "password='flexisip'|MARIADB_ROOT_PASSWORD=flexisip|MARIADB_PASSWORD=flexisip" .env.example docker-compose.yml config/flexisip-conference.conf; then
  echo 'error: default database credential remains' >&2
  exit 1
fi

echo 'static repository checks passed'
