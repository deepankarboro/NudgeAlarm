#!/bin/bash
# Bumps marketing version (patch) + build number on Product → Archive.
# Example: 1.0.0 (1) → 1.0.1 (2) → 1.0.2 (3)
# Updates PulseWake/Version.xcconfig (single source of truth).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="${ROOT}/PulseWake/Version.xcconfig"

should_bump() {
  # Xcode Archive pre-action sets ACTION=install for the archive build.
  if [[ "${ACTION:-}" == "install" ]]; then
    return 0
  fi
  # Manual / CI: BUMP_VERSION=1 ./scripts/bump_build_number.sh
  if [[ "${BUMP_VERSION:-}" == "1" ]]; then
    return 0
  fi
  return 1
}

if ! should_bump; then
  exit 0
fi

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "error: missing ${VERSION_FILE}" >&2
  exit 1
fi

read_marketing() {
  grep '^MARKETING_VERSION' "$VERSION_FILE" | sed 's/^MARKETING_VERSION *= *//;s/;//;s/^[[:space:]]*//;s/[[:space:]]*$//'
}

read_build() {
  grep '^CURRENT_PROJECT_VERSION' "$VERSION_FILE" | sed 's/^CURRENT_PROJECT_VERSION *= *//;s/;//;s/^[[:space:]]*//;s/[[:space:]]*$//'
}

bump_patch_marketing() {
  local current="$1"
  local -a parts
  local major=0 minor=0 patch=0
  IFS='.' read -ra parts <<< "$current"
  major="${parts[0]:-0}"
  minor="${parts[1]:-0}"
  patch="${parts[2]:-0}"
  patch=$((patch + 1))
  echo "${major}.${minor}.${patch}"
}

CURRENT_MARKETING="$(read_marketing)"
CURRENT_BUILD="$(read_build)"
NEW_MARKETING="$(bump_patch_marketing "$CURRENT_MARKETING")"

if [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] && [[ ${#CURRENT_BUILD} -le 6 ]]; then
  NEW_BUILD=$((10#${CURRENT_BUILD} + 1))
else
  # Legacy timestamp-style build numbers (e.g. 202607291034) → start sequential at 2.
  NEW_BUILD=2
fi

tmp="$(mktemp)"
awk -v marketing="$NEW_MARKETING" -v build="$NEW_BUILD" '
  /^MARKETING_VERSION = / { print "MARKETING_VERSION = " marketing; next }
  /^CURRENT_PROJECT_VERSION = / { print "CURRENT_PROJECT_VERSION = " build; next }
  { print }
' "$VERSION_FILE" > "$tmp"
mv "$tmp" "$VERSION_FILE"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "PulseWake release version bump (Archive)"
echo "  Version: ${CURRENT_MARKETING} (${CURRENT_BUILD}) → ${NEW_MARKETING} (${NEW_BUILD})"
echo "  Updated: PulseWake/Version.xcconfig"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Commit Version.xcconfig after uploading to TestFlight."
