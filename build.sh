#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/" && pwd)"

# Prefer the repo's venv when present so dependencies (e.g. proxmoxer) are available
# even if direnv isn't active.
if [[ -x "$repo_root/.venv/bin/python3" ]]; then
  exec "$repo_root/.venv/bin/python3" "$repo_root/build.py" "$@"
fi

exec python3 "$repo_root/build.py" "$@"
