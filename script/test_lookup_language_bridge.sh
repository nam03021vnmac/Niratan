#!/usr/bin/env bash
# test-requires-path: .build/xcode-source-packages/checkouts/hoshidicts/include
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCTS="${HOSHI_TEST_PRODUCTS:-}"
if [[ -z "$PRODUCTS" ]]; then
  OBJECT="$(ls -t "$ROOT"/.build/xcode-derived-data*/Build/Products/Debug/CHoshiDicts.o 2>/dev/null | head -n 1)"
  PRODUCTS="$(dirname "$OBJECT")"
fi
[[ -f "$PRODUCTS/CHoshiDicts.o" && -f "$PRODUCTS/libzstd.o" ]] || {
  echo "Build Niratan before running the shared lookup language bridge test." >&2
  exit 1
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/niratan-lookup-bridge.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 6 -cxx-interoperability-mode=default \
  -I "$ROOT/.build/xcode-source-packages/checkouts/hoshidicts/include" \
  -import-objc-header "$ROOT/Core/HoshiLookupBridge.hpp" \
  "$ROOT/script/test_lookup_language_bridge.swift" \
  "$PRODUCTS/CHoshiDicts.o" "$PRODUCTS/libzstd.o" -lsqlite3 \
  -o "$WORK/test"
"$WORK/test"
