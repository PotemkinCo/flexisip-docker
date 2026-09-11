#!/usr/bin/env bash
set -euo pipefail

registry=${REGISTRY:-ghcr.io}
owner=${IMAGE_OWNER:-potemkinco}
proxy_version=${FLEXISIP_VERSION:?FLEXISIP_VERSION is required}
conference_version=${FLEXISIP_CONFERENCE_VERSION:?FLEXISIP_CONFERENCE_VERSION is required}
proxy_image="${registry}/${owner}/flexisip-proxy:${proxy_version}"
conference_image="${registry}/${owner}/flexisip-conference:${conference_version}"

docker pull "$proxy_image"
docker pull "$conference_image"

actual=$(docker run --rm --entrypoint flexisip "$proxy_image" --version)
echo "proxy version: $actual"
if ! grep -Eq "flexisip[[:space:]]+version: ${proxy_version}([[:space:]]|$)" <<<"$actual"; then
  echo "error: proxy image version does not match ${proxy_version}" >&2
  exit 1
fi

plugin_dir=/opt/belledonne-communications/flexisip-conference/lib/liblinphone/plugins
found=$(docker run --rm "$conference_image" sh -c \
  "ls -1 '$plugin_dir' 2>/dev/null | grep -E 'ektserver.*\\.so$' || true")
if [[ -z "$found" ]]; then
  echo "error: no EKT plugin found in $plugin_dir" >&2
  docker run --rm "$conference_image" ls -la "$plugin_dir" >&2 || true
  exit 1
fi
echo "conference EKT plugin: $found"

if ! docker run --rm "$conference_image" test -x /usr/local/bin/entrypoint.sh; then
  echo 'error: conference entrypoint is not executable' >&2
  exit 1
fi

echo 'image verification passed'
