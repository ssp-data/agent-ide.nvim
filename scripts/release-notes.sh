#!/usr/bin/env bash
# Print one section of CHANGELOG.md: the given version (without "v"), or "Unreleased" by default.
set -euo pipefail
cd "$(dirname "$0")/.."
want="${1:-Unreleased}"
awk -v want="$want" '
  /^## \[/ {
    if (found) exit
    name = $0; sub(/^## \[/, "", name); sub(/\].*$/, "", name)
    if (name == want) { found = 1; next }
  }
  found { print }
' CHANGELOG.md | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | sed '/./,$!d'
