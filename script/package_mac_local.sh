#!/usr/bin/env bash
# Builds an ad-hoc signed local test DMG without Google sign-in credentials.
# Google Drive sign-in and sync do not work in the result; never distribute it.
# usage: script/package_mac_local.sh [version]   (default: <MARKETING_VERSION>-local)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [version]" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  VERSION="$1"
else
  MARKETING_VERSION="$(
    sed -n 's/^[[:space:]]*MARKETING_VERSION = \([0-9][0-9.]*\);.*/\1/p' Niratan.xcodeproj/project.pbxproj | sort -u
  )"
  if [[ -z "$MARKETING_VERSION" || "$MARKETING_VERSION" == *$'\n'* ]]; then
    echo "Could not determine a single MARKETING_VERSION; pass a version explicitly." >&2
    exit 1
  fi
  VERSION="$MARKETING_VERSION-local"
fi

# Release signing identity is deliberately ignored: local builds are ad-hoc.
HOSHI_SKIP_GOOGLE_SIGNIN_VERIFY=1 HOSHI_RELEASE_SIGNING_IDENTITY=- bash script/package_mac.sh "$VERSION"
