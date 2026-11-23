#!/bin/sh
# EngVPN SmartDNS / domain+IP bypass — local list wired to transparent routing.
# Domains → data/run/bypass.routing.json (Xray/sing-box direct rules).
# IPs/CIDRs → iptables RETURN before REDIRECT/TPROXY (ENGVPN_BYPASS chain).
#
#   smartdns.sh status|apply|stop|dry-run|write
#
# Config: $DATA_DIR/smartdns.conf  (enabled=0|1)
# List:   $DATA_DIR/smartdns-bypass.txt  (one domain, IP, or CIDR per line; # comments)
set -u

SHARE=$(cd "${0%/*}" 2>/dev/null && pwd -P) || exit 1
PREFIX=${SHARE%/share/engvpn}
DATA_DIR=${ENGVPN_DATA_DIR:-$PREFIX/data}
CONF=$DATA_DIR/smartdns.conf
LIST=$DATA_DIR/smartdns-bypass.txt
RUN=$DATA_DIR/run
ROUTING=$RUN/bypass.routing.json
CHAIN=ENGVPN_BYPASS
PATH=/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH

enabled=0

load_conf() {
	[ -f "$CONF" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		'' | \#*) continue ;;
		enabled=*) enabled=${line#enabled=} ;;
		esac
	done <"$CONF"
}

ipt() {
	if iptables -w 2 -h >/dev/null 2>&1; then
		iptables -w 2 "$@"
	else
		iptables "$@"
	fi
}

is_ip() {
	case "$1" in
	*.*.*.*) return 0 ;;
	esac
	return 1
}

is_cidr() {
	case "$1" in
	*.*.*.*/*) return 0 ;;
	esac
	return 1
}

write_routing() {
	mkdir -p "$RUN"
	domains=""
	ips=""
	if [ -f "$LIST" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			case "$line" in
			'' | \#*) continue ;;
			esac
			entry=$(echo "$line" | tr -d ' \t\r')
			[ -z "$entry" ] && continue
			if is_cidr "$entry" || is_ip "$entry"; then
				ips="$ips,\"$entry\""
			else
				# strip optional domain: / full: prefix
				case "$entry" in
				domain:*) entry=${entry#domain:} ;;
				full:*) entry=${entry#full:} ;;
				esac
				domains="$domains,\"domain:$entry\""
			fi
		done <"$LIST"
	fi
	domains=${domains#,}
	ips=${ips#,}
	cat >"$ROUTING" <<EOF
{
  "tag": "engvpn-smartdns-bypass",
  "enabled": $([ "$enabled" = 1 ] && echo true || echo false),
  "rules": [
    {
      "type": "field",
      "outboundTag": "direct",
      "domain": [${domains}],
      "ip": [${ips}]
    }
  ]
}
EOF
	# Also a simple text list for engines that prefer files
	: >"$RUN/bypass.domains"
	: >"$RUN/bypass.ips"
	if [ -f "$LIST" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			case "$line" in
			'' | \#*) continue ;;
			esac
			entry=$(echo "$line" | tr -d ' \t\r')
			[ -z "$entry" ] && continue
			if is_cidr "$entry" || is_ip "$entry"; then
				echo "$entry" >>"$RUN/bypass.ips"
			else
				case "$entry" in
				domain:*) entry=${entry#domain:} ;;
				full:*) entry=${entry#full:} ;;
				esac
				echo "$entry" >>"$RUN/bypass.domains"
			fi
		done <"$LIST"
	fi
	echo "wrote $ROUTING"
}

flush_bypass() {
	# Unhook from ENGVPN parent if present, then flush
	ipt -t nat -D ENGVPN -j "$CHAIN" 2>/dev/null || true
	ipt -t mangle -D ENGVPN -j "$CHAIN" 2>/dev/null || true
	ipt -t nat -F "$CHAIN" 2>/dev/null || true
	ipt -t nat -X "$CHAIN" 2>/dev/null || true
	ipt -t mangle -F "$CHAIN" 2>/dev/null || true
	ipt -t mangle -X "$CHAIN" 2>/dev/null || true
}

apply_ip_bypass() {
	[ "$enabled" = 1 ] || return 0
	[ -f "$LIST" ] || return 0
	# Insert RETURN rules for destination IPs into ENGVPN chain (nat + mangle)
	# Prefer a dedicated sub-chain jumped early from ENGVPN.
	for tbl in nat mangle; do
		# Only if parent ENGVPN chain exists
		ipt -t "$tbl" -L ENGVPN -n >/dev/null 2>&1 || continue
		ipt -t "$tbl" -N "$CHAIN" 2>/dev/null || ipt -t "$tbl" -F "$CHAIN" 2>/dev/null || true
		while IFS= read -r line || [ -n "$line" ]; do
			case "$line" in
			'' | \#*) continue ;;
			esac
			entry=$(echo "$line" | tr -d ' \t\r')
			if is_cidr "$entry" || is_ip "$entry"; then
				ipt -t "$tbl" -A "$CHAIN" -d "$entry" -j RETURN 2>/dev/null || true
			fi
		done <"$LIST"
		# Jump to bypass at the top of ENGVPN (after recreate, insert as first rule)
		ipt -t "$tbl" -C ENGVPN -j "$CHAIN" 2>/dev/null ||
			ipt -t "$tbl" -I ENGVPN 1 -j "$CHAIN" 2>/dev/null || true
	done
}

apply_all() {
	load_conf
	write_routing
	flush_bypass
	if [ "$enabled" = 1 ]; then
		apply_ip_bypass
		echo "smartdns: applied enabled=1"
	else
		echo "smartdns: applied enabled=0 (routing file only)"
	fi
}

stop_all() {
	flush_bypass
	enabled=0
	write_routing
	echo "smartdns: stopped"
}

dry_run() {
	load_conf
	echo "enabled=$enabled"
	echo "conf=$CONF"
	echo "list=$LIST"
	if [ -f "$LIST" ]; then
		echo "entries:"
		grep -v '^#' "$LIST" | grep -v '^$' || true
	else
		echo "entries: (none)"
	fi
	write_routing
}

status() {
	load_conf
	n=0
	[ -f "$LIST" ] && n=$(grep -cvE '^#|^$' "$LIST" 2>/dev/null || echo 0)
	echo "enabled=$enabled entries=$n routing=$ROUTING"
	if ipt -t nat -L "$CHAIN" -n >/dev/null 2>&1; then
		echo "iptables=active"
	else
		echo "iptables=inactive"
	fi
}

ACTION=${1:-status}
case "$ACTION" in
apply | start) apply_all ;;
stop) stop_all ;;
status) status ;;
dry-run) dry_run ;;
write)
	load_conf
	write_routing
	;;
*)
	echo "Usage: $0 status|apply|stop|dry-run|write" >&2
	exit 2
	;;
esac
