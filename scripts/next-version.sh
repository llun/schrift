#!/usr/bin/env bash
#
# Print the next semantic version (X.Y.Z, no leading "v") for an automated
# TestFlight release, derived from Conventional Commits.
#
# The current version is the most recent `v*` tag (or 0.0.0 if none exists).
# The bump level is inferred from the commits since that tag:
#
#   major : a commit whose body contains `BREAKING CHANGE` / `BREAKING-CHANGE`,
#           or whose subject has a `!` after the type (e.g. `feat!:`,
#           `fix(scope)!:`)
#   minor : otherwise, any `feat:` / `feat(scope):` subject
#   patch : otherwise (fix/chore/docs/refactor/… or a non-conventional subject)
#
# The bump is never lower than patch, so every merge to main ships at least a
# patch release even when the commit messages don't follow the convention.
#
# Used by .github/workflows/testflight.yml. Prints exactly one line to stdout.
set -euo pipefail

latest_tag="$(git tag --list 'v*' --sort=-v:refname | head -n1 || true)"

if [ -n "$latest_tag" ]; then
  base="${latest_tag#v}"
  range="${latest_tag}..HEAD"
else
  base="0.0.0"
  range="HEAD" # whole history when the repo has never been tagged
fi

IFS='.' read -r major minor patch <<< "$base"
major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"

subjects="$(git log "$range" --no-merges --format='%s')"
bodies="$(git log "$range" --no-merges --format='%B')"

level="patch"
if printf '%s\n' "$bodies"   | grep -qiE 'BREAKING[ -]CHANGE' \
   || printf '%s\n' "$subjects" | grep -qE '^[A-Za-z]+(\([^)]*\))?!:'; then
  level="major"
elif printf '%s\n' "$subjects" | grep -qE '^feat(\([^)]*\))?:'; then
  level="minor"
fi

case "$level" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
esac

printf '%s.%s.%s\n' "$major" "$minor" "$patch"
