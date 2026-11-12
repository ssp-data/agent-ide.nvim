#!/usr/bin/env bash
# Push the release commit and tag, and create the GitHub release from the tag's RELEASE_NOTES.md.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: make publish VERSION=x.y.z" >&2; exit 2; }
tag="v$version"
branch="${RELEASE_BRANCH:-main}"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null || { echo "no tag $tag; run make release VERSION=$version first" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh (GitHub CLI) is needed to create the release" >&2; exit 1; }

# The notes as they were when the tag was cut; the changelog section for a tag made before them.
notes="$(git show "$tag:RELEASE_NOTES.md" 2>/dev/null || scripts/changelog-section.sh "$version")"
[ -n "$notes" ] || { echo "no release notes for $tag" >&2; exit 1; }
git push origin "$branch" "$tag"
gh release create "$tag" --title "$tag" --notes "$notes"
