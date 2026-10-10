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
  echo "Build Niratan before running PDF dictionary integration." >&2
  exit 1
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/niratan-pdf-lookup.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
python3 - "$WORK" <<'PY'
import json,sys,zipfile
from pathlib import Path
root=Path(sys.argv[1])
with zipfile.ZipFile(root/'dictionary.zip','w',zipfile.ZIP_DEFLATED) as z:
    z.writestr('index.json',json.dumps({'title':'PDF Lookup Fixture','format':3,'revision':'fixture-1','sequenced':True}))
    z.writestr('term_bank_1.json',json.dumps([
        ['日本語','にほんご','','n',0,['Japanese language'],1,''],
        ['勉強','べんきょう','','n',0,['Study'],2,'']
    ],ensure_ascii=False))
PY
xcrun swiftc -parse-as-library -swift-version 6 -cxx-interoperability-mode=default \
  -I "$ROOT/.build/xcode-source-packages/checkouts/hoshidicts/include" \
  -import-objc-header "$ROOT/Core/HoshiLookupBridge.hpp" \
  "$ROOT/Models/PDF.swift" "$ROOT/Models/Profile.swift" \
  "$ROOT/Core/SelectionLookup/TextSelectionResolver.swift" \
  "$ROOT/Features/PDF/PDFLookupSelectionResolver.swift" \
  "$ROOT/script/test_pdf_dictionary_lookup.swift" \
  "$PRODUCTS/CHoshiDicts.o" "$PRODUCTS/libzstd.o" -lsqlite3 \
  -o "$WORK/test"
"$WORK/test" "$WORK"
