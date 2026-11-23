#!/bin/sh
# EngVPN transparent / selective VPN — open iptables REDIRECT (and TPROXY when available).
# No stealthsurf-nfqws. Works with Xray/sing-box dokodemo (or TPROXY) inbound on LOCAL_PORT.
#
#   transparent.sh start|stop|status|apply|dry-run|write-state
#
# Config file: $DATA_DIR/transparent.conf  (key=value)
#   mode=off|all|selected|exclude     # default off
#   method=redirect|tproxy            # default redirect (widest Merlin support)
#   port=12345                        # local dokodemo / tproxy listen port
#   mark=0x39000                      # fwmark (isolated from SurfGate 0x20000 / XrayUI 0x10000)
#   table=79                          # policy routing table
#   killswitch=0|1                    # block non-marked WAN forward when on
#   lan_if=br0
#   lan_cidr=192.168.50.0/24
#   dns_hijack=0|1                    # REDIRECT LAN :53 → EngVPN DNS (dns_port)
#   dns_port=5353                     # panel DNS relay (alfa dns.mjs)
#   captive_open=0|1                  # hotel/café portal: passthrough (no redirect)
#
# Device list: $DATA_DIR/devices.select  (one IP or MAC per line; # comments)
set -u

SHARE=$(cd "${0%/*}" 2>/dev/null && pwd -P) || exit 1
PREFIX=${SHARE%/share/engvpn}
DATA_DIR=${ENGVPN_DATA_DIR:-$PREFIX/data}
CONF=$DATA_DIR/transparent.conf
DEVICES=$DATA_DIR/devices.select
STATE_DIR=$DATA_DIR/netfilter
STATE=$STATE_DIR/rules
CHAIN=ENGVPN
KS_CHAIN=ENGVPN_KS
DIVERT_CHAIN=ENGVPN_DIVERT
PATH=/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH

# Defaults
mode=off
method=redirect
port=12345
mark=0x39000
table=79
killswitch=0
lan_if=br0
lan_cidr=""
dns_hijack=0
dns_port=5353
captive_open=0

load_conf() {
	[ -f "$CONF" ] || return 0
	# shellcheck disable=SC1090
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		'' | \#*) continue ;;
		*=*)
			key=${line%%=*}
			val=${line#*=}
			case "$key" in
			mode | method | port | mark | table | killswitch | lan_if | lan_cidr | dns_hijack | dns_port | captive_open)
				# method: redirect | tproxy | auto | prefer-tproxy
				eval "$key=\$val"
				;;
			esac
			;;
		esac
	done <"$CONF"
}

detect_lan() {
	if [ -z "$lan_cidr" ] && type nvram >/dev/null 2>&1; then
		ip=$(nvram get lan_ipaddr 2>/dev/null)
		mask=$(nvram get lan_netmask 2>/dev/null)
		[ -n "$ip" ] && [ -n "$mask" ] && lan_cidr=$(ip_to_cidr "$ip" "$mask")
	fi
	[ -n "$lan_cidr" ] || lan_cidr=192.168.50.0/24
	if [ -z "$lan_if" ] || [ "$lan_if" = br0 ]; then
		type nvram >/dev/null 2>&1 && lan_if=$(nvram get lan_ifname 2>/dev/null)
		[ -n "$lan_if" ] || lan_if=br0
	fi
}

ip_to_cidr() {
	# BusyBox-friendly: common Merlin masks only
	case "$2" in
	255.255.255.0) echo "${1%.*}.0/24" ;;
	255.255.0.0) echo "${1%.*.*}.0.0/16" ;;
	255.0.0.0) echo "${1%%.*}.0.0.0/8" ;;
	255.255.255.128) echo "$1/25" ;;
	*) echo "${1%.*}.0/24" ;;
	esac
}

# Prefer a bounded wait: bare -w can block forever if another process holds xtables.
ipt() {
	if iptables -w 2 -h >/dev/null 2>&1; then
		iptables -w 2 "$@"
	else
		iptables "$@"
	fi
}

# Detect TPROXY + UDP support. Prefer module presence, then live iptables probe.
# Returns: 0 = full TCP+UDP TPROXY, 1 = unavailable
have_tproxy() {
	[ "${ENGVPN_SMOKE:-}" = 1 ] && return 1
	# Kernel modules (Merlin often needs them loaded)
	if ! lsmod 2>/dev/null | grep -q xt_TPROXY; then
		modprobe xt_TPROXY 2>/dev/null || modprobe tproxy 2>/dev/null || true
	fi
	if ! lsmod 2>/dev/null | grep -q xt_socket; then
		modprobe xt_socket 2>/dev/null || true
	fi
	ipt -t mangle -N ENGVPN_TP_PROBE 2>/dev/null || true
	ok=0
	if ipt -t mangle -A ENGVPN_TP_PROBE -p tcp -j TPROXY --on-port 1 --tproxy-mark 1 2>/dev/null; then
		ipt -t mangle -D ENGVPN_TP_PROBE -p tcp -j TPROXY --on-port 1 --tproxy-mark 1 2>/dev/null || true
		# Also probe UDP — full parity needs both
		if ipt -t mangle -A ENGVPN_TP_PROBE -p udp -j TPROXY --on-port 1 --tproxy-mark 1 2>/dev/null; then
			ipt -t mangle -D ENGVPN_TP_PROBE -p udp -j TPROXY --on-port 1 --tproxy-mark 1 2>/dev/null || true
			ok=1
		else
			# TCP-only TPROXY still better than REDIRECT for TCP; allow it
			ok=1
			echo "transparent: UDP TPROXY probe failed — TCP TPROXY only" >&2
		fi
	fi
	ipt -t mangle -F ENGVPN_TP_PROBE 2>/dev/null || true
	ipt -t mangle -X ENGVPN_TP_PROBE 2>/dev/null || true
	[ "$ok" = 1 ]
}

# Auto-prefer TPROXY when method=auto or unset preference and modules allow.
resolve_method() {
	case "$method" in
	tproxy)
		if ! have_tproxy; then
			echo "transparent: TPROXY unavailable; falling back to redirect (TCP only, no UDP divert)" >&2
			method=redirect
		fi
		;;
	auto | prefer-tproxy)
		if have_tproxy; then
			method=tproxy
			echo "transparent: auto-selected TPROXY+UDP" >&2
		else
			method=redirect
			echo "transparent: auto-selected REDIRECT (no xt_TPROXY)" >&2
		fi
		;;
	redirect | "")
		method=redirect
		;;
	esac
}

flush_chain() {
	tbl=$1
	ch=$2
	ipt -t "$tbl" -F "$ch" 2>/dev/null || true
	ipt -t "$tbl" -X "$ch" 2>/dev/null || true
}

ensure_chain() {
	tbl=$1
	ch=$2
	ipt -t "$tbl" -N "$ch" 2>/dev/null || ipt -t "$tbl" -F "$ch" 2>/dev/null || true
}

unlink_hooks() {
	ipt -t nat -D PREROUTING -j "$CHAIN" 2>/dev/null || true
	ipt -t mangle -D PREROUTING -j "$CHAIN" 2>/dev/null || true
	ipt -t mangle -D PREROUTING -p tcp -m socket --transparent -j "$DIVERT_CHAIN" 2>/dev/null || true
	ipt -t filter -D FORWARD -j "$KS_CHAIN" 2>/dev/null || true
}

clear_policy_route() {
	ip rule del fwmark "$mark" table "$table" 2>/dev/null || true
	ip route flush table "$table" 2>/dev/null || true
}

stop_rules() {
	unlink_hooks
	flush_chain nat "$CHAIN"
	flush_chain mangle "$CHAIN"
	flush_chain mangle "$DIVERT_CHAIN"
	flush_chain filter "$KS_CHAIN"
	clear_policy_route
	rm -f "$STATE"
	echo "transparent: stopped"
}

# Emit one RETURN/match helper for selected/exclude lists into chain $1 table $2
# $3 = action for matched selected devices: jump target or empty for exclude (RETURN for exclude match)
apply_device_matches() {
	tbl=$1
	ch=$2
	action=$3
	[ -f "$DEVICES" ] || return 0
	while IFS= read -r entry || [ -n "$entry" ]; do
		case "$entry" in
		'' | \#*) continue ;;
		esac
		entry=$(echo "$entry" | tr 'A-F' 'a-f' | tr -d ' \t\r')
		case "$entry" in
		*:*:*:*:*:*)
			# MAC
			if [ "$action" = RETURN ]; then
				ipt -t "$tbl" -A "$ch" -m mac --mac-source "$entry" -j RETURN 2>/dev/null || true
			else
				ipt -t "$tbl" -A "$ch" -m mac --mac-source "$entry" -j "$action" 2>/dev/null || true
			fi
			;;
		*.*.*.*)
			if [ "$action" = RETURN ]; then
				ipt -t "$tbl" -A "$ch" -s "$entry" -j RETURN 2>/dev/null || true
			else
				ipt -t "$tbl" -A "$ch" -s "$entry" -j "$action" 2>/dev/null || true
			fi
			;;
		esac
	done <"$DEVICES"
}

write_state_file() {
	mkdir -p "$STATE_DIR"
	pid=${ENGVPN_TRANSPARENT_PID:-$$}
	boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
	{
		echo "pid $pid"
		echo "boot $boot"
		echo "mode $mode"
		echo "method $method"
		echo "port $port"
		echo "mark $mark"
		echo "iptables $(command -v iptables 2>/dev/null || echo /usr/sbin/iptables)"
		# Replay hints (family table verb chain rest)
		echo "4 nat chain $CHAIN"
		echo "4 mangle chain $CHAIN"
		if [ "$killswitch" = 1 ]; then
			echo "4 filter chain $KS_CHAIN"
		fi
		echo "4 nat hook PREROUTING -j $CHAIN"
		if [ "$method" = tproxy ]; then
			echo "4 mangle hook PREROUTING -j $CHAIN"
		fi
	} >"$STATE"
}

# LAN DNS :53 → EngVPN DNS relay (adblock / dnsViaVpn / dnsLock). Skip when captive portal is open.
build_dns_hijack() {
	[ "$dns_hijack" = 1 ] || return 0
	[ "$captive_open" = 1 ] && return 0
	dp=${dns_port:-5353}
	# Allow DNS to router itself / private without forcing through relay first? Hijack all LAN :53.
	ipt -t nat -A "$CHAIN" -i "$lan_if" -p udp --dport 53 -j REDIRECT --to-ports "$dp" 2>/dev/null || true
	ipt -t nat -A "$CHAIN" -i "$lan_if" -p tcp --dport 53 -j REDIRECT --to-ports "$dp" 2>/dev/null || true
}

# Build redirect rules into ENGVPN (nat)
build_redirect() {
	ensure_chain nat "$CHAIN"
	ipt -t nat -A "$CHAIN" -i "$lan_if" -p tcp -d "$lan_cidr" -j RETURN
	ipt -t nat -A "$CHAIN" -i "$lan_if" -p tcp -d 127.0.0.0/8 -j RETURN
	ipt -t nat -A "$CHAIN" -i "$lan_if" -p tcp -d 10.0.0.0/8 -j RETURN
	ipt -t nat -A "$CHAIN" -i "$lan_if" -p tcp -d 172.16.0.0/12 -j RETURN
	ipt -t nat -A "$CHAIN" -i "$lan_if" -p tcp -d 192.168.0.0/16 -j RETURN
	ipt -t nat -A "$CHAIN" -i "$lan_if" -p tcp -d 169.254.0.0/16 -j RETURN
	# Never redirect EngVPN panel / socks / http edge
	for p in "${ENGVPN_PORT:-8790}" 20808 20809 20828; do
		ipt -t nat -A "$CHAIN" -i "$lan_if" -p tcp --dport "$p" -j RETURN
	done

	# Captive portal open: passthrough so hotel/café login pages work
	if [ "$captive_open" = 1 ]; then
		ipt -t nat -A "$CHAIN" -j RETURN
		ipt -t nat -C PREROUTING -j "$CHAIN" 2>/dev/null || ipt -t nat -I PREROUTING 1 -j "$CHAIN"
		return 0
	fi

	build_dns_hijack

	case "$mode" in
	selected)
		# Only listed devices → REDIRECT; others RETURN
		ensure_chain nat ENGVPN_SEL
		ipt -t nat -F ENGVPN_SEL 2>/dev/null || true
		ipt -t nat -A ENGVPN_SEL -p tcp -j REDIRECT --to-ports "$port"
		apply_device_matches nat "$CHAIN" ENGVPN_SEL
		ipt -t nat -A "$CHAIN" -j RETURN
		;;
	exclude)
		apply_device_matches nat "$CHAIN" RETURN
		ipt -t nat -A "$CHAIN" -i "$lan_if" -p tcp -j REDIRECT --to-ports "$port"
		;;
	all)
		ipt -t nat -A "$CHAIN" -i "$lan_if" -p tcp -j REDIRECT --to-ports "$port"
		;;
	esac
	ipt -t nat -C PREROUTING -j "$CHAIN" 2>/dev/null || ipt -t nat -I PREROUTING 1 -j "$CHAIN"
}

build_tproxy() {
	ensure_chain mangle "$CHAIN"
	ensure_chain mangle "$DIVERT_CHAIN"
	ipt -t mangle -A "$DIVERT_CHAIN" -j MARK --set-mark "$mark"
	ipt -t mangle -A "$DIVERT_CHAIN" -j ACCEPT
	ipt -t mangle -C PREROUTING -p tcp -m socket --transparent -j "$DIVERT_CHAIN" 2>/dev/null ||
		ipt -t mangle -I PREROUTING 1 -p tcp -m socket --transparent -j "$DIVERT_CHAIN" 2>/dev/null || true

	ipt -t mangle -A "$CHAIN" -i "$lan_if" -d "$lan_cidr" -j RETURN
	ipt -t mangle -A "$CHAIN" -i "$lan_if" -d 127.0.0.0/8 -j RETURN
	ipt -t mangle -A "$CHAIN" -i "$lan_if" -d 10.0.0.0/8 -j RETURN
	ipt -t mangle -A "$CHAIN" -i "$lan_if" -d 172.16.0.0/12 -j RETURN
	ipt -t mangle -A "$CHAIN" -i "$lan_if" -d 192.168.0.0/16 -j RETURN

	# DNS hijack still uses nat REDIRECT → EngVPN :5353 (even when traffic is TPROXY)
	ensure_chain nat "$CHAIN"
	if [ "$captive_open" = 1 ]; then
		ipt -t nat -A "$CHAIN" -j RETURN
		ipt -t nat -C PREROUTING -j "$CHAIN" 2>/dev/null || ipt -t nat -I PREROUTING 1 -j "$CHAIN"
		ipt -t mangle -A "$CHAIN" -j RETURN
		ipt -t mangle -C PREROUTING -j "$CHAIN" 2>/dev/null || ipt -t mangle -I PREROUTING 1 -j "$CHAIN"
		return 0
	fi
	build_dns_hijack
	ipt -t nat -C PREROUTING -j "$CHAIN" 2>/dev/null || ipt -t nat -I PREROUTING 1 -j "$CHAIN"

	add_tp() {
		proto=$1
		ipt -t mangle -A "$CHAIN" -i "$lan_if" -p "$proto" -j TPROXY --on-port "$port" --tproxy-mark "$mark" 2>/dev/null || true
	}

	case "$mode" in
	selected)
		ensure_chain mangle ENGVPN_SEL
		ipt -t mangle -F ENGVPN_SEL 2>/dev/null || true
		ipt -t mangle -A ENGVPN_SEL -p tcp -j TPROXY --on-port "$port" --tproxy-mark "$mark" 2>/dev/null || true
		ipt -t mangle -A ENGVPN_SEL -p udp -j TPROXY --on-port "$port" --tproxy-mark "$mark" 2>/dev/null || true
		apply_device_matches mangle "$CHAIN" ENGVPN_SEL
		ipt -t mangle -A "$CHAIN" -j RETURN
		;;
	exclude)
		apply_device_matches mangle "$CHAIN" RETURN
		add_tp tcp
		add_tp udp
		;;
	all)
		add_tp tcp
		add_tp udp
		;;
	esac
	ipt -t mangle -C PREROUTING -j "$CHAIN" 2>/dev/null || ipt -t mangle -I PREROUTING 1 -j "$CHAIN"

	ip rule add fwmark "$mark" table "$table" 2>/dev/null || true
	ip route replace local default dev lo table "$table" 2>/dev/null || true
}

build_killswitch() {
	[ "$killswitch" = 1 ] || return 0
	ensure_chain filter "$KS_CHAIN"
	ipt -t filter -A "$KS_CHAIN" -m mark --mark "$mark" -j RETURN 2>/dev/null || true
	# Allow LAN / established
	ipt -t filter -A "$KS_CHAIN" -m state --state ESTABLISHED,RELATED -j RETURN 2>/dev/null ||
		ipt -t filter -A "$KS_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null || true
	ipt -t filter -A "$KS_CHAIN" -d "$lan_cidr" -j RETURN
	ipt -t filter -A "$KS_CHAIN" -o "$lan_if" -j RETURN
	# Block other forwarded traffic from LAN when kill-switch on
	ipt -t filter -A "$KS_CHAIN" -i "$lan_if" -j REJECT --reject-with icmp-host-unreachable 2>/dev/null ||
		ipt -t filter -A "$KS_CHAIN" -i "$lan_if" -j DROP
	ipt -t filter -C FORWARD -j "$KS_CHAIN" 2>/dev/null || ipt -t filter -I FORWARD 1 -j "$KS_CHAIN"
}

dokodemo_hint() {
	mkdir -p "$DATA_DIR/run"
	cat >"$DATA_DIR/run/dokodemo.inbound.json" <<EOF
{
  "tag": "engvpn-transparent",
  "listen": "0.0.0.0",
  "port": $port,
  "protocol": "dokodemo-door",
  "settings": { "network": "tcp,udp", "followRedirect": true },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
  "streamSettings": { "sockopt": { "tproxy": "$([ "$method" = tproxy ] && echo tproxy || echo off)" } }
}
EOF
}

apply_rules() {
	load_conf
	detect_lan
	# Fully off (no DNS hijack, no captive passthrough marker)
	if [ "$mode" = off ] && [ "$dns_hijack" != 1 ] && [ "$captive_open" != 1 ]; then
		stop_rules
		echo "transparent: mode=off"
		return 0
	fi
	resolve_method
	# Persist resolved method so panel/status stay honest
	if [ -f "$CONF" ]; then
		tmp=$CONF.tmp.$$
		awk -v m="$method" '
			BEGIN { done=0 }
			/^method=/ { print "method=" m; done=1; next }
			{ print }
			END { if (!done) print "method=" m }
		' "$CONF" >"$tmp" && mv "$tmp" "$CONF"
	fi
	# Rebuild cleanly
	unlink_hooks
	flush_chain nat "$CHAIN"
	flush_chain nat ENGVPN_SEL
	flush_chain mangle "$CHAIN"
	flush_chain mangle ENGVPN_SEL
	flush_chain mangle "$DIVERT_CHAIN"
	flush_chain filter "$KS_CHAIN"
	clear_policy_route

	# DNS-only (transparent VPN off): hijack :53 without TCP REDIRECT/TPROXY of LAN traffic
	if [ "$mode" = off ] && [ "$captive_open" != 1 ]; then
		ensure_chain nat "$CHAIN"
		build_dns_hijack
		ipt -t nat -C PREROUTING -j "$CHAIN" 2>/dev/null || ipt -t nat -I PREROUTING 1 -j "$CHAIN"
		write_state_file
		echo "transparent: dns_hijack-only port=$dns_port"
		return 0
	fi

	if [ "$method" = tproxy ]; then
		build_tproxy
	else
		build_redirect
	fi
	build_killswitch
	dokodemo_hint
	write_state_file
	# Re-hook SmartDNS IP bypass into the fresh ENGVPN chain
	if [ -x "$SHARE/smartdns.sh" ]; then
		sh "$SHARE/smartdns.sh" apply >/dev/null 2>&1 || true
	fi
	echo "transparent: applied mode=$mode method=$method port=$port killswitch=$killswitch dns_hijack=$dns_hijack captive_open=$captive_open lan=$lan_cidr if=$lan_if"
}

dry_run() {
	load_conf
	detect_lan
	echo "mode=$mode method=$method port=$port mark=$mark table=$table killswitch=$killswitch"
	echo "lan_if=$lan_if lan_cidr=$lan_cidr"
	echo "conf=$CONF devices=$DEVICES"
	# Avoid live iptables probes on smoke; report module / capability hints.
	if [ "${ENGVPN_SMOKE:-}" = 1 ]; then
		echo "tproxy_available=skipped"
		echo "udp_tproxy=skipped"
		echo "fallback=redirect"
	else
		if have_tproxy; then
			echo "tproxy_available=yes"
			echo "udp_tproxy=yes"
			echo "recommended_method=tproxy"
		elif lsmod 2>/dev/null | grep -q xt_TPROXY; then
			echo "tproxy_available=maybe"
			echo "udp_tproxy=unknown"
			echo "recommended_method=tproxy"
		else
			echo "tproxy_available=no"
			echo "udp_tproxy=no"
			echo "recommended_method=redirect"
			echo "fallback_note=TCP REDIRECT only; UDP needs xt_TPROXY + dokodemo tproxy"
		fi
	fi
	[ -f "$DEVICES" ] && echo "devices:" && grep -v '^#' "$DEVICES" | grep -v '^$' || echo "devices: (none)"
	dokodemo_hint
	echo "wrote $DATA_DIR/run/dokodemo.inbound.json"
}

status() {
	load_conf
	if ipt -t nat -L "$CHAIN" -n >/dev/null 2>&1 || ipt -t mangle -L "$CHAIN" -n >/dev/null 2>&1; then
		echo "active mode=$mode method=$method port=$port"
		[ -f "$STATE" ] && echo "state=$STATE"
		return 0
	fi
	echo "inactive mode=$mode"
	return 1
}

ACTION=${1:-status}
case "$ACTION" in
start | apply) apply_rules ;;
stop) stop_rules ;;
status) status ;;
dry-run) dry_run ;;
write-state)
	load_conf
	detect_lan
	write_state_file
	echo "wrote $STATE"
	;;
*)
	echo "Usage: $0 start|stop|status|apply|dry-run|write-state" >&2
	exit 2
	;;
esac
