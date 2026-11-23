#!/bin/sh
# EngVPN LAN discovery — ARP / ip neigh / dnsmasq leases / Merlin clientlist.
# Prints JSON lines: {"ip":"...","mac":"...","name":"...","online":true|false}
# Env: ENGVPN_DATA_DIR, ENGVPN_SMOKE=1 (demo fixtures when no real neigh)
set -u

PATH=/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH

SHARE=$(cd "${0%/*}" 2>/dev/null && pwd -P) || exit 1
PREFIX=${SHARE%/share/engvpn}
DATA_DIR=${ENGVPN_DATA_DIR:-$PREFIX/data}
OUT=${1:-}
TMP=${TMPDIR:-/tmp}/engvpn-discover.$$

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP"

# name cache: mac(lowercase) → name
NAMES=$TMP/names
: >"$NAMES"

add_name() {
	mac=$(echo "$1" | tr 'A-F' 'a-f')
	name=$2
	[ -n "$mac" ] && [ -n "$name" ] || return 0
	echo "$mac	$name" >>"$NAMES"
}

lookup_name() {
	mac=$(echo "$1" | tr 'A-F' 'a-f')
	awk -F'	' -v m="$mac" '$1==m { print $2; exit }' "$NAMES"
}

# Merlin / Asus custom client names
if type nvram >/dev/null 2>&1; then
	# custom_clientlist: <name>mac>… or similar; also dhcp_staticlist
	clist=$(nvram get custom_clientlist 2>/dev/null || true)
	# Format often: <Name>AA:BB:CC:DD:EE:FF>0>0>…
	printf '%s' "$clist" | tr '<' '\n' | while IFS= read -r row || [ -n "$row" ]; do
		case "$row" in
		*\>*\>* )
			name=${row%%\>*}
			rest=${row#*\>}
			mac=${rest%%\>*}
			add_name "$mac" "$name"
			;;
		esac
	done
	static=$(nvram get dhcp_staticlist 2>/dev/null || true)
	# <mac>ip>hostname>
	printf '%s' "$static" | tr '<' '\n' | while IFS= read -r row || [ -n "$row" ]; do
		case "$row" in
		*\>*\>* )
			mac=${row%%\>*}
			rest=${row#*\>}
			ip=${rest%%\>*}
			host=${rest#*\>}
			host=${host%%\>*}
			[ -n "$host" ] && add_name "$mac" "$host"
			_=$ip
			;;
		esac
	done
fi

# dnsmasq leases: epoch mac ip host clientid
for lease in /var/lib/misc/dnsmasq.leases /tmp/dnsmasq.leases /tmp/var/lib/misc/dnsmasq.leases \
	/jffs/dnsmasq.leases "$DATA_DIR/dnsmasq.leases"; do
	[ -f "$lease" ] || continue
	while IFS= read -r line || [ -n "$line" ]; do
		# shellcheck disable=SC2086
		set -- $line
		[ $# -ge 4 ] || continue
		mac=$2
		ip=$3
		host=$4
		case "$host" in
		\* | '') host="" ;;
		esac
		[ -n "$host" ] && add_name "$mac" "$host"
		echo "$ip	$mac	$host" >>"$TMP/lease"
	done <"$lease"
done

# /proc/net/arp
ARP=$TMP/arp
: >"$ARP"
if [ -f /proc/net/arp ]; then
	awk 'NR>1 && $4!="00:00:00:00:00:00" {
		ip=$1; mac=tolower($4); print ip "\t" mac
	}' /proc/net/arp >>"$ARP"
fi

# ip neigh
if command -v ip >/dev/null 2>&1; then
	ip neigh show 2>/dev/null | awk '
		$1 ~ /^[0-9]+\./ {
			ip=$1; mac=""; st=""
			for (i=1;i<=NF;i++) {
				if ($i=="lladdr") mac=$(i+1)
				if ($i=="REACHABLE" || $i=="STALE" || $i=="DELAY" || $i=="PROBE" || $i=="PERMANENT") st=$i
				if ($i=="FAILED" || $i=="INCOMPLETE") st=$i
			}
			if (mac!="") print ip "\t" tolower(mac) "\t" st
		}' >>"$TMP/neigh"
fi

# Merge into unique IP map
ALL=$TMP/all
: >"$ALL"
append_row() {
	ip=$1
	mac=$2
	online=${3:-1}
	case "$ip" in
	"" | 0.0.0.0 | 127.* | 169.254.*) return 0 ;;
	esac
	case "$mac" in
	"" | 00:00:00:00:00:00 | ff:ff:ff:ff:ff:ff) return 0 ;;
	esac
	mac=$(echo "$mac" | tr 'A-F' 'a-f')
	echo "$ip	$mac	$online" >>"$ALL"
}

[ -f "$TMP/lease" ] && while IFS= read -r line || [ -n "$line" ]; do
	IFS='	' read -r ip mac host <<EOF
$line
EOF
	append_row "$ip" "$mac" 1
done <"$TMP/lease"

[ -f "$ARP" ] && while IFS= read -r line || [ -n "$line" ]; do
	IFS='	' read -r ip mac <<EOF
$line
EOF
	append_row "$ip" "$mac" 1
done <"$ARP"

[ -f "$TMP/neigh" ] && while IFS= read -r line || [ -n "$line" ]; do
	IFS='	' read -r ip mac st <<EOF
$line
EOF
	on=1
	case "$st" in
	FAILED | INCOMPLETE) on=0 ;;
	esac
	append_row "$ip" "$mac" "$on"
done <"$TMP/neigh"

# Deduplicate by IP (last wins)
sort -k1,1 "$ALL" 2>/dev/null | awk -F'	' '
{
	ip=$1; mac=$2; on=$3
	ips[ip]=mac; online[ip]=on
}
END {
	for (ip in ips) print ip "\t" ips[ip] "\t" online[ip]
}' >"$TMP/uniq"

count=0
: >"$TMP/jsonl"
while IFS= read -r line || [ -n "$line" ]; do
	[ -z "$line" ] && continue
	IFS='	' read -r ip mac on <<EOF
$line
EOF
	name=$(lookup_name "$mac")
	[ -z "$name" ] && name=$ip
	# Escape for JSON
	esc_name=$(printf '%s' "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')
	online=true
	[ "$on" = 0 ] && online=false
	printf '{"ip":"%s","mac":"%s","name":"%s","online":%s}\n' "$ip" "$mac" "$esc_name" "$online" >>"$TMP/jsonl"
	count=$((count + 1))
done <"$TMP/uniq"

# Smoke / empty: optional fixture
if [ "$count" = 0 ] && [ "${ENGVPN_SMOKE:-}" = 1 ] && [ -f "$DATA_DIR/discover.fixture.jsonl" ]; then
	cat "$DATA_DIR/discover.fixture.jsonl" >"$TMP/jsonl"
	count=$(wc -l <"$TMP/jsonl" | tr -d ' ')
fi

if [ -n "$OUT" ]; then
	cp -f "$TMP/jsonl" "$OUT"
else
	cat "$TMP/jsonl"
fi
echo "count=$count" >&2
