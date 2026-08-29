#!/usr/bin/env bash
# One-shot "save my work": stage everything, commit with a plain-English
# description, then let the post-commit hook (version-bump.sh) record a version
# row and push the branch + tag with --force-with-lease.
#
# Usage:
#   scripts/save.sh <plain description of the change>
#   scripts/save.sh "feat: add X"        # a Conventional-Commits prefix drives the bump
#
# The description (minus any conventional prefix) becomes the ledger's Change cell.
# `git add -A` still honours .gitignore, so ignored working files are never swept in.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

desc="$*"
if [ -z "$desc" ]; then
  echo "usage: scripts/save.sh <plain description>" >&2
  exit 1
fi

git add -A || exit 1
if git diff --cached --quiet; then
  echo "Nothing to commit."
  exit 0
fi

note="$(printf '%s' "$desc" | sed -E 's/^[a-z]+(\([^)]*\))?!?:[[:space:]]*//')"
printf '%s\n' "$note" > .git/version-note.md

case "$desc" in
  feat:*|fix:*|chore:*|refactor:*|test:*|docs:*|perf:*|ci:*|*\):*) subject="$desc" ;;
  *) subject="chore: $desc" ;;
esac

git commit -m "$subject"
