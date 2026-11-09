#!/bin/sh
# Ensure junk outbound-ss-*.json is moved out of geodata data/ before recompile
set -e
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

datadir="$TMP/data"
junkdir="$TMP/data.junk"
mkdir -p "$datadir" "$junkdir"
printf 'example.com\n' >"$datadir/mylist"
printf '{"tag":"ss-230924"}\n' >"$datadir/outbound-ss-230924.json"
printf 'x\n' >"$datadir/keep.fp"
printf 'domain.com @cn\n' >"$datadir/withattrs"

geodata_is_list_file() {
    case "$1" in
    outbound-* | *.json | *.asp | *.fp | *.bak | *.tmp | *.tar.gz | stealthsurf | xrayui | xraydatbuilder | v2dat)
        return 1
        ;;
    esac
    return 0
}

for f in "$datadir"/*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    if ! geodata_is_list_file "$base"; then
        mv -f "$f" "$junkdir/$base"
    fi
done

test -f "$datadir/mylist"
test -f "$datadir/withattrs"
test ! -f "$datadir/outbound-ss-230924.json"
test -f "$junkdir/outbound-ss-230924.json"
test -f "$junkdir/keep.fp"

echo "geodata_sanitize.spec.sh OK"
