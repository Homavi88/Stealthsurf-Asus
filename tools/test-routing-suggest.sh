#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
fail=0
pass() { echo "OK  $1"; }
bad() {
  echo "FAIL $1"
  fail=$((fail + 1))
}

grep -q 'SS_ROUTING_SUGGEST' "$ROOT/src/ui/routing-suggest.js" && pass "suggest pack" || bad "suggest pack"
grep -q 'youtube.com' "$ROOT/src/ui/routing-suggest.js" && pass "domain suggest" || bad "domain suggest"
grep -q 'category-ru' "$ROOT/src/ui/routing-suggest.js" && pass "geosite suggest" || bad "geosite suggest"
grep -q 'showRuleSuggest' "$ROOT/src/ui/app.js" && pass "UI suggest fn" || bad "UI suggest fn"
grep -q 'btnAddRule' "$ROOT/src/ui/index.asp" && pass "ASP add rule" || bad "ASP add rule"
grep -q 'rulesTable' "$ROOT/src/ui/index.asp" && pass "ASP rules table" || bad "ASP rules table"
grep -q 'routing-suggest.js' "$ROOT/src/ui/index.asp" && pass "ASP loads suggest js" || bad "ASP loads suggest js"
grep -q 'routing-suggest.js' "$ROOT/tools/pack.sh" && pass "pack includes suggest" || bad "pack includes suggest"
grep -q 'routing-suggest.js' "$ROOT/src/backend/mount.sh" && pass "mount links suggest" || bad "mount links suggest"

# Node smoke: filter startsWith
node --input-type=module -e '
import { createRequire } from "module";
import { pathToFileURL } from "url";
import { readFileSync } from "fs";
const src = readFileSync("'"$ROOT"'/src/ui/routing-suggest.js","utf8");
eval(src.replace("window.SS_ROUTING_SUGGEST","globalThis.SS_ROUTING_SUGGEST"));
const domains = globalThis.SS_ROUTING_SUGGEST.domains;
const q="you";
const hits=domains.filter(d=>d.startsWith(q)||d.includes(q));
if(!hits.includes("youtube.com")) process.exit(1);
' && pass "node domain filter" || bad "node domain filter"

if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail"
  exit 1
fi
echo "ALL PASS"
