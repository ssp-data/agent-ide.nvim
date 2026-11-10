#!/usr/bin/env bash
# Cut a release locally: changelog section, helper version, commit, annotated tag. Never pushes.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: make release VERSION=x.y.z" >&2
  exit 2
fi
tag="v$version"
branch="$(git rev-parse --abbrev-ref HEAD)"

[ "$branch" = "${RELEASE_BRANCH:-main}" ] || { echo "release from ${RELEASE_BRANCH:-main}, not $branch (or set RELEASE_BRANCH)" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "the working tree is not clean" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "tag $tag exists" >&2; exit 1; }
grep -q '^## \[Unreleased\]' CHANGELOG.md || { echo "CHANGELOG.md has no [Unreleased] section" >&2; exit 1; }
notes="$(scripts/release-notes.sh Unreleased)"
[ -n "$notes" ] || { echo "nothing under [Unreleased] in CHANGELOG.md" >&2; exit 1; }

if [ "${SKIP_TESTS:-}" != 1 ]; then
  make test
  if command -v cargo >/dev/null; then make test-helper; fi
fi

today="$(date +%Y-%m-%d)"
awk -v v="$version" -v d="$today" '
  /^## \[Unreleased\]/ && !done { print "## [Unreleased]\n\n## [" v "] - " d; done = 1; next }
  { print }
' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md

# The helper carries the same version.
awk -v v="$version" '!done && /^version = "/ { print "version = \"" v "\""; done = 1; next } { print }' helper/Cargo.toml > helper/Cargo.toml.tmp && mv helper/Cargo.toml.tmp helper/Cargo.toml
if command -v cargo >/dev/null; then cargo build --release --manifest-path helper/Cargo.toml >/dev/null; fi

git add CHANGELOG.md helper/Cargo.toml
git ls-files --error-unmatch helper/Cargo.lock >/dev/null 2>&1 && git add helper/Cargo.lock
git commit -q -m "release $tag"
git tag -a "$tag" -m "Agent-IDE.nvim $tag" -m "$notes"

echo "Released $tag locally (commit and tag). Nothing was pushed."
echo "Publish with: make publish VERSION=$version"
