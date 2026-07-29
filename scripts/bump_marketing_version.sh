#!/bin/bash
# Bump user-facing marketing version in PulseWake/Version.xcconfig
# Usage: ./scripts/bump_marketing_version.sh patch|minor|major

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 patch|minor|major" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="${ROOT}/PulseWake/Version.xcconfig"
PBXPROJ="${ROOT}/PulseWake.xcodeproj/project.pbxproj"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "error: missing ${VERSION_FILE}" >&2
  exit 1
fi

CURRENT="$(grep '^MARKETING_VERSION' "$VERSION_FILE" | sed 's/^MARKETING_VERSION *= *//;s/;//;s/^[[:space:]]*//')"
IFS='.' read -ra PARTS <<< "$CURRENT"
MAJOR="${PARTS[0]:-0}"
MINOR="${PARTS[1]:-0}"
PATCH="${PARTS[2]:-0}"

case "$1" in
  patch) PATCH=$((PATCH + 1)) ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  *)
    echo "Usage: $0 patch|minor|major" >&2
    exit 1
    ;;
esac

NEW="${MAJOR}.${MINOR}.${PATCH}"
tmp="$(mktemp)"
sed "s/^MARKETING_VERSION = .*/MARKETING_VERSION = ${NEW}/" "$VERSION_FILE" > "$tmp"
mv "$tmp" "$VERSION_FILE"

echo "PulseWake marketing version: ${CURRENT} → ${NEW}"
echo "(Archive auto-bumps patch; use this script for minor/major only.)"
