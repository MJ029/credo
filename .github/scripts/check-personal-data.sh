#!/usr/bin/env bash
# Fails when the repository contains a developer's digital footprint:
#   1. absolute home-directory paths (/Users/<name>, /home/<name>)
#   2. personal email addresses
#   3. (pull requests) commits authored or committed with a non-noreply email
# Generic placeholders such as /Users/me/ and you@example.com are allowed.
set -euo pipefail

fail=0
self=".github/scripts/check-personal-data.sh"
files=$(git ls-files -z | tr '\0' '\n' | grep -v -e "^${self}$" || true)

scan() { # scan <label> <grep -E pattern> <regex of allowed placeholder matches>
  local label=$1 pattern=$2 allowed=$3 hits
  # One "file:line:match" row per match, so an allowed placeholder on a line can't hide a leak.
  hits=$(printf '%s\n' "$files" | while IFS= read -r f; do
    [ -f "$f" ] && grep -InoE -- "$pattern" "$f" 2>/dev/null | sed "s|^|$f:|" || true
  done | grep -Ev -- "^[^:]+:[0-9]+:(${allowed})$" || true)
  if [ -n "$hits" ]; then
    echo "::error::$label found:"
    # Show location only, never the matched value.
    printf '%s\n' "$hits" | cut -d: -f1,2 | sed 's/^/  /'
    fail=1
  fi
}

scan "home-directory path" '/(Users|home)/[A-Za-z0-9._-]+' '/Users/(me|you|user|username|Shared)|/home/(runner|user|you)'
scan "email address" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
  '.*@users\.noreply\.github\.com|.*@example\.(com|org|net)|noreply@(github|anthropic)\.com'

if [ -n "${BASE_SHA:-}" ] && [ -n "${HEAD_SHA:-}" ]; then
  bad=$(git log --format='%h %ae %ce' "${BASE_SHA}..${HEAD_SHA}" |
    awk '{ for (i = 2; i <= 3; i++) if ($i !~ /@users\.noreply\.github\.com$/ && $i != "noreply@github.com") { print $1; break } }' || true)
  if [ -n "$bad" ]; then
    echo "::error::commits with a non-noreply author/committer email (rewrite with a GitHub noreply address):"
    printf '%s\n' "$bad" | sed 's/^/  /'
    fail=1
  fi
fi

[ "$fail" -eq 0 ] && echo "No personal data found."
exit "$fail"
