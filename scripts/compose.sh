#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "error: .env is missing; copy .env.example to .env and set all required secrets" >&2
  exit 1
fi
if [[ ! -f production.env ]]; then
  echo "error: production.env is missing" >&2
  exit 1
fi

exec docker compose --env-file .env --env-file production.env "$@"
