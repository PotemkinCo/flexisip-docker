#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <gitlab-project> <github-owner/repository>" >&2
  exit 64
fi

gitlab_project=$1
github_repo=$2
encoded_project=${gitlab_project//\//%2F}
response=''
source_name=''

for attempt in {1..5}; do
  if candidate=$(curl -fsSL --connect-timeout 15 --max-time 45 \
      "https://gitlab.linphone.org/api/v4/projects/${encoded_project}/repository/tags?per_page=100") \
      && jq -e 'type == "array"' >/dev/null <<<"$candidate"; then
    response=$candidate
    source_name=GitLab
    break
  fi
  echo "GitLab tag API failed (attempt ${attempt}/5); retrying" >&2
  sleep 5
done

if [[ -z "$response" ]]; then
  echo "GitLab tag API unavailable; using the official GitHub mirror" >&2
  github_headers=(-H 'Accept: application/vnd.github+json')
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    github_headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  response=$(curl -fsSL --connect-timeout 15 --max-time 45 \
    "${github_headers[@]}" \
    "https://api.github.com/repos/${github_repo}/tags?per_page=100")
  source_name='GitHub mirror'
fi

latest=$(jq -r '
  [.[] | (.name // .ref // empty)
   | select(type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))]
  | sort_by(split(".") | map(tonumber))
  | last // empty
' <<<"$response")

if [[ -z "$latest" ]]; then
  echo "error: no stable semantic-version tag found ($source_name)" >&2
  exit 1
fi

echo "${latest}"
