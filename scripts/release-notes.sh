#!/usr/bin/env bash
# Draft RELEASE_NOTES.md for a version from what changed since the previous tag: the changelog's
# [Unreleased] section and the commits. With the `claude` CLI the notes are written in prose
# (scripts/release-notes-prompt.md); without it a draft with the raw sources is written for
# editing by hand. Review the file, then commit it; `make release` requires that.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
prev="${2:-}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: make release-notes VERSION=x.y.z [PREV=vX.Y.Z]" >&2
  exit 2
fi
[ -n "$prev" ] || prev="$(git describe --tags --abbrev=0 2>/dev/null || true)"
[ -n "$prev" ] || { echo "no previous tag found; pass PREV=<tag or commit>" >&2; exit 1; }
git rev-parse -q --verify "$prev^{commit}" >/dev/null || { echo "unknown revision $prev" >&2; exit 1; }

echo "Drafting RELEASE_NOTES.md for v$version (changes since $prev)…"
if command -v claude >/dev/null; then
  # env -u ANTHROPIC_API_KEY: the Claude Code login, not a stray API key from the shell.
  sed -e "s/{{VERSION}}/v$version/g" -e "s/{{PREV}}/$prev/g" scripts/release-notes-prompt.md \
    | env -u ANTHROPIC_API_KEY claude -p --allowedTools "Read,Write,Bash(git log:*),Bash(git diff:*),Bash(git describe:*),Bash(head:*)"
else
  {
    echo "## What has changed?"; echo; echo "<intro>"; echo
    echo "**Highlights**"; echo; echo "- "; echo
    echo "**Fixes**"; echo; echo "- "; echo
    echo "<!-- sources, for editing by hand; delete when done -->"; echo
    echo "<!-- CHANGELOG.md [Unreleased] -->"; echo
    scripts/changelog-section.sh Unreleased; echo
    echo "<!-- commits since $prev -->"; echo
    git log --no-merges --format='- %s' "$prev..HEAD"
  } > RELEASE_NOTES.md
  echo "claude CLI not found: wrote the sources into RELEASE_NOTES.md; edit them into prose"
fi
echo
echo "Review RELEASE_NOTES.md, then: git add RELEASE_NOTES.md && git commit -m 'release notes v$version'"
echo "Then: make release VERSION=$version"
