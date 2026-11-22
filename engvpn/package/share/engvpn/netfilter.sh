#!/bin/sh
# EngVPN netfilter helper.
#
# Intentional gap vs StealthSurf: full transparent TPROXY / kill-switch chains
# are not shipped as a closed binary. This script:
#   - ensures the panel TCP port is accepted on INPUT
#   - can load a simple optional rules file written by future transparent mode
#
# State file format (optional, word-safe tokens only):
#   iptables <path-to-iptables>
#   4 mangle chain ENGVPN_PRE
#   4 mangle rule ENGVPN_PRE -j RETURN
#   4 mangle hook PREROUTING -j ENGVPN_PRE

set -u
SHARE=$(cd "${0%/*}" 2>/dev/null && pwd) || exit 0
PREFIX=${SHARE%/share/engvpn}
STATE=${ENGVPN_NETFILTER_STATE:-$PREFIX/data/netfilter/rules}
PORT=${ENGVPN_PORT:-8790}

ensure_panel_port() {
	type iptables >/dev/null 2>&1 || return 0
	iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null ||
		iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
}

replay() {
	ensure_panel_port
	[ -r "$STATE" ] || {
		echo none
		return 0
	}
	# Minimal replay: recreate named chains listed in state (best-effort).
	tool=$(awk '$1 == "iptables" { print $2; exit }' "$STATE")
	[ -n "$tool" ] && [ -x "$tool" ] || tool=$(command -v iptables 2>/dev/null || true)
	[ -n "$tool" ] || {
		echo none
		return 0
	}
	replayed=
	set -f
	while read -r family table verb chain rest; do
		[ "$family" = 4 ] || continue
		case "$verb" in
		chain)
			"$tool" -t "$table" -N "$chain" 2>/dev/null || true
			replayed=1
			;;
		rule)
			"$tool" -t "$table" -C "$chain" $rest >/dev/null 2>&1 ||
				"$tool" -t "$table" -A "$chain" $rest 2>/dev/null || true
			replayed=1
			;;
		hook)
			"$tool" -t "$table" -C "$chain" $rest >/dev/null 2>&1 ||
				"$tool" -t "$table" -I "$chain" $rest 2>/dev/null || true
			replayed=1
			;;
		esac
	done <"$STATE"
	set +f
	if [ -n "$replayed" ]; then
		echo replayed
	else
		echo none
	fi
}

case "${1:-ensure-port}" in
ensure-port) ensure_panel_port ;;
replay) replay ;;
*)
	echo "Usage: $0 ensure-port|replay" >&2
	exit 2
	;;
esac
