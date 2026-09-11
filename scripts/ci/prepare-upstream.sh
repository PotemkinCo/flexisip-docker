#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <flexisip|flexisip-conference> <tag> <destination>" >&2
  exit 64
fi

project=$1
tag=$2
destination=$3
root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
proxy_pid=''
chrome_bin=${CHROME_BIN:-}

case "$project" in
  flexisip)
    upstream_repo='https://gitlab.linphone.org/BC/public/flexisip.git'
    ;;
  flexisip-conference)
    upstream_repo='https://gitlab.linphone.org/BC/public/flexisip-conference.git'
    ;;
  *)
    echo "error: unsupported upstream project: $project" >&2
    exit 64
    ;;
esac

cleanup() {
  if [[ -n "$proxy_pid" ]]; then
    kill "$proxy_pid" 2>/dev/null || true
  fi
  pkill -f 'gitlab-proxy.js' 2>/dev/null || true
  pkill -f 'google-chrome.*9222' 2>/dev/null || true
}
trap cleanup EXIT

cd "$root_dir/scripts"
npm ci --ignore-scripts --no-audit --no-fund
chrome_bin=${chrome_bin:-$(command -v google-chrome-stable || command -v chromium || true)}
if [[ -z "$chrome_bin" ]]; then
  echo "error: Chrome/Chromium is required for the GitLab proxy" >&2
  exit 1
fi

nohup env CHROME_BIN="$chrome_bin" node gitlab-proxy.js >gitlab-proxy.log 2>&1 &
proxy_pid=$!
for _ in {1..30}; do
  if curl -fsS --max-time 5 http://127.0.0.1:8843/explore/projects >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if ! curl -fsS --max-time 5 http://127.0.0.1:8843/explore/projects >/dev/null 2>&1; then
  echo 'error: GitLab proxy failed to start' >&2
  sed -n '1,160p' gitlab-proxy.log >&2 || true
  exit 1
fi

cd "$root_dir"
git config --global url.http://127.0.0.1:8843/.insteadOf https://gitlab.linphone.org/

for attempt in {1..5}; do
  rm -rf -- "$destination"
  if git clone --depth 1 --branch "$tag" "$upstream_repo" "$destination"; then
    break
  fi
  if [[ "$attempt" == 5 ]]; then
    echo "error: failed to clone $project at $tag" >&2
    exit 1
  fi
  echo "clone failed (attempt ${attempt}/5); retrying" >&2
  sleep 15
done

cd "$root_dir/$destination"
for attempt in {1..5}; do
  if git submodule update --init --recursive --filter=blob:none \
      && git submodule foreach --recursive 'git reset --hard HEAD'; then
    if [[ "$(git submodule status --recursive | grep -c '^-' || true)" == 0 ]]; then
      echo "prepared $project $tag"
      exit 0
    fi
  fi
  if [[ "$attempt" == 5 ]]; then
    echo "error: failed to initialize all submodules for $project $tag" >&2
    exit 1
  fi
  echo "submodule fetch failed (attempt ${attempt}/5); retrying" >&2
  rm -rf .git/modules/* 2>/dev/null || true
  git submodule foreach --recursive 'rm -rf "$(pwd)"' 2>/dev/null || true
  sleep 30
done
