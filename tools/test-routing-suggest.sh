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
grep -q 'normalizeDomainEntry' "$ROOT/src/ui/app.js" && pass "UI normalize domain" || bad "UI normalize domain"
grep -q 'ruleDomainList' "$ROOT/src/ui/app.js" && pass "UI rule domain list" || bad "UI rule domain list"
grep -q 'btnAddRule' "$ROOT/src/ui/index.asp" && pass "ASP add rule" || bad "ASP add rule"
grep -q 'id="ruleDomains"' "$ROOT/src/ui/index.asp" && pass "ASP multi domain field" || bad "ASP multi domain field"
grep -q 'id="ruleOutbound"' "$ROOT/src/ui/index.asp" && pass "ASP outbound select" || bad "ASP outbound select"
grep -q 'ss-prefix-tag' "$ROOT/src/ui/index.asp" && pass "ASP prefix tags" || bad "ASP prefix tags"
grep -q 'rulesTable' "$ROOT/src/ui/index.asp" && pass "ASP rules table" || bad "ASP rules table"
grep -q 'routing-suggest.js' "$ROOT/src/ui/index.asp" && pass "ASP loads suggest js" || bad "ASP loads suggest js"
grep -q 'routing-suggest.js' "$ROOT/tools/pack.sh" && pass "pack includes suggest" || bad "pack includes suggest"
grep -q 'routing-suggest.js' "$ROOT/src/backend/mount.sh" && pass "mount links suggest" || bad "mount links suggest"
grep -q 'normalize_domains' "$ROOT/src/backend/routing.sh" && pass "routing multi domain builder" || bad "routing multi domain builder"
grep -q 'domain\[\]' "$ROOT/src/backend/dnsmasq.sh" && pass "dnsmasq reads domain[]" || bad "dnsmasq reads domain[]"

node --input-type=module -e '
import { readFileSync } from "fs";
const root = "'"$ROOT"'";
const src = readFileSync(root + "/src/ui/routing-suggest.js", "utf8");
eval(src.replace("window.SS_ROUTING_SUGGEST", "globalThis.SS_ROUTING_SUGGEST"));
const domains = globalThis.SS_ROUTING_SUGGEST.domains;
const hits = domains.filter((d) => d.startsWith("you") || d.includes("you"));
if (!hits.includes("youtube.com")) process.exit(1);
const app = readFileSync(root + "/src/ui/app.js", "utf8");
function extract(name) {
  const marker = "function " + name + "(";
  const start = app.indexOf(marker);
  if (start < 0) throw new Error("missing " + name);
  let i = app.indexOf("{", start);
  let depth = 0;
  for (; i < app.length; i++) {
    if (app[i] === "{") depth++;
    else if (app[i] === "}") {
      depth--;
      if (depth === 0) return app.slice(start, i + 1);
    }
  }
  throw new Error("unclosed " + name);
}
const normalizeDomainEntry = new Function("return (" + extract("normalizeDomainEntry") + ")")();
const normalizeIpEntry = new Function("return (" + extract("normalizeIpEntry") + ")")();
const splitRuleLines = new Function("return (" + extract("splitRuleLines") + ")")();
if (normalizeDomainEntry("https://YouTube.com/watch") !== "domain:youtube.com") process.exit(2);
if (normalizeDomainEntry("geosite:youtube") !== "geosite:youtube") process.exit(3);
if (normalizeDomainEntry("full:Example.COM/x") !== "full:example.com") process.exit(4);
if (normalizeIpEntry("ru") !== "geoip:ru") process.exit(5);
if (normalizeIpEntry("10.0.0.0/8") !== "10.0.0.0/8") process.exit(6);
if (splitRuleLines("a\nb\n\nc").join(",") !== "a,b,c") process.exit(7);
' && pass "node domain/normalize smoke" || bad "node domain/normalize smoke"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' '{"rules":[{"name":"mix","outbound":"ss-1","priority":1,"domain":["domain:youtube.com","geosite:netflix"],"ip":["geoip:private","8.8.8.8"]}]}' >"$TMP/routing.json"
built=$(jq -nc --slurpfile rt "$TMP/routing.json" --arg def "direct" '
  def normalize_domains: map(tostring) | map(select(length > 0));
  def normalize_ips:
    map(tostring) | map(
      if test("^geoip:"; "i") then ("geoip:" + (sub("^geoip:";"";"i")))
      elif test("^[0-9.]+(/[0-9]+)?$") or test("^[0-9a-fA-F:]+(/[0-9]+)?$") then .
      else ("geoip:" + .) end
    ) | map(select(length > 0));
  def legacy_from(r):
    (r.type // "domain") as $t |
    (r.matcher // r.value // "") as $m |
    if ($m | tostring | length) == 0 then {domain:[], ip:[]}
    elif $t == "geoip" then {domain:[], ip:["geoip:"+$m]}
    elif $t == "ip" or $t == "cidr" then {domain:[], ip:[$m]}
    elif $t == "geosite" then {domain:["geosite:"+$m], ip:[]}
    elif $t == "full" then {domain:["full:"+$m], ip:[]}
    elif $t == "keyword" then {domain:["keyword:"+$m], ip:[]}
    elif $t == "regexp" then {domain:["regexp:"+$m], ip:[]}
    else {domain:["domain:"+$m], ip:[]} end;
  def rule_from(r):
    (r.outbound // $def) as $o |
    (
      if ((r.domain != null) or (r.ip != null)) then
        { domain: ((r.domain // []) | normalize_domains), ip: ((r.ip // []) | normalize_ips) }
      else legacy_from(r) end
    ) as $m |
    if (($m.domain|length) == 0) and (($m.ip|length) == 0) then empty
    else
      {type:"field", outboundTag:$o}
      + (if ($m.domain|length) > 0 then {domain:$m.domain} else {} end)
      + (if ($m.ip|length) > 0 then {ip:$m.ip} else {} end)
    end;
  [ (( $rt[0].rules // [] )[] | rule_from(.) ) ]
')
echo "$built" | jq -e '.[0].outboundTag == "ss-1"
  and (.[0].domain | index("domain:youtube.com"))
  and (.[0].domain | index("geosite:netflix"))
  and (.[0].ip | index("geoip:private"))
  and (.[0].ip | index("8.8.8.8"))' >/dev/null \
  && pass "jq multi matcher rule" || bad "jq multi matcher rule"

printf '%s\n' '{"rules":[{"name":"yt","type":"geosite","matcher":"youtube","outbound":"direct","priority":1}]}' >"$TMP/routing.json"
built=$(jq -nc --slurpfile rt "$TMP/routing.json" --arg def "direct" '
  def legacy_from(r):
    (r.type // "domain") as $t | (r.matcher // "") as $m |
    if $t == "geosite" then {domain:["geosite:"+$m], ip:[]} else {domain:["domain:"+$m], ip:[]} end;
  def rule_from(r):
    (r.outbound // $def) as $o | legacy_from(r) as $m |
    {type:"field", outboundTag:$o, domain:$m.domain};
  [ (( $rt[0].rules // [] )[] | rule_from(.) ) ]
')
echo "$built" | jq -e '.[0].domain == ["geosite:youtube"]' >/dev/null \
  && pass "jq legacy geosite" || bad "jq legacy geosite"

if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail"
  exit 1
fi
echo "ALL PASS"
