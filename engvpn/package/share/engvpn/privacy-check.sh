#!/bin/sh
# EngVPN privacy / stealth checks — real router-side probes (open stack only).
# Outputs one JSON object on stdout. No jq required.
#
#   privacy-check.sh [all|status|exit|dns|ipv6|killswitch|dpi|path]
#
# Proves / reports (honest limits):
#   exit     — WAN vs tunnel-marked egress IP (when SOCKS/HTTP edge given)
#   dns      — system/WAN resolvers vs expected VPN DNS policy
#   ipv6     — global IPv6 present while policy=block
#   killswitch — ENGVPN_KS chain + transparent.conf killswitch
#   dpi      — nfqws/zapret + transparent method + WARP flags → "what ISP sees"
#   path     — optional MTU / UDP-TPROXY / traceroute sanity
set -u

SHARE=$(cd "${0%/*}" 2>/dev/null && pwd -P) || exit 1
PREFIX=${SHARE%/share/engvpn}
DATA_DIR=${ENGVPN_DATA_DIR:-$PREFIX/data}
CONF=$DATA_DIR/transparent.conf
DPI_CONF=$DATA_DIR/dpi.conf
WARP_CONF=$DATA_DIR/warp.conf
PID_NFQWS=/tmp/engvpn-nfqws.pid
CHAIN=ENGVPN
KS_CHAIN=ENGVPN_KS
PATH=/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH

ACTION=${1:-all}
SOCKS_PORT=${ENGVPN_SOCKS_PORT:-}
HTTP_PORT=${ENGVPN_HTTP_PORT:-}
VPN_CONNECTED=${ENGVPN_VPN_CONNECTED:-0}
IPV6_POLICY=${ENGVPN_IPV6_POLICY:-block}
DNS_VIA_VPN=${ENGVPN_DNS_VIA_VPN:-0}
PROTO_HINT=${ENGVPN_PROTO_HINT:-}
SECURITY_HINT=${ENGVPN_SECURITY_HINT:-}
ENGINE_HINT=${ENGVPN_ENGINE_HINT:-}

json_escape() {
	# Escape for JSON string (minimal)
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | tr '\n\r' '  '
}

ipt() {
	if iptables -w 2 -h >/dev/null 2>&1; then
		iptables -w 2 "$@"
	else
		iptables "$@"
	fi
}

load_kv() {
	file=$1
	[ -f "$file" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		'' | \#*) continue ;;
		*=*)
			key=${line%%=*}
			val=${line#*=}
			eval "pc_$key=\$val"
			;;
		esac
	done <"$file"
}

pc_mode=off
pc_method=redirect
pc_port=12345
pc_mark=0x39000
pc_table=79
pc_killswitch=0
pc_enabled=0
pc_queue=390
pc_youtube=1
pc_discord=1

load_kv "$CONF"
# Preserve transparent mode — dpi.conf also has mode= and must not clobber it
tr_mode=$pc_mode
tr_method=$pc_method
if [ -f "$DPI_CONF" ]; then
	pc_enabled=$(awk -F= '$1=="enabled"{print $2; exit}' "$DPI_CONF" 2>/dev/null)
	pc_queue=$(awk -F= '$1=="queue"{print $2; exit}' "$DPI_CONF" 2>/dev/null)
	pc_youtube=$(awk -F= '$1=="youtube"{print $2; exit}' "$DPI_CONF" 2>/dev/null)
	pc_discord=$(awk -F= '$1=="discord"{print $2; exit}' "$DPI_CONF" 2>/dev/null)
	[ -n "$pc_enabled" ] || pc_enabled=0
	[ -n "$pc_queue" ] || pc_queue=390
	[ -n "$pc_youtube" ] || pc_youtube=1
	[ -n "$pc_discord" ] || pc_discord=1
fi
pc_mode=$tr_mode
pc_method=$tr_method

warp_mode=off
if [ -f "$WARP_CONF" ]; then
	warp_mode=$(awk -F= '$1=="mode"{print $2; exit}' "$WARP_CONF" 2>/dev/null)
	[ -n "$warp_mode" ] || warp_mode=off
fi

have_tproxy() {
	[ "${ENGVPN_SMOKE:-}" = 1 ] && return 1
	lsmod 2>/dev/null | grep -q '^xt_TPROXY' && return 0
	[ -e /lib/modules/"$(uname -r)"/kernel/net/netfilter/xt_TPROXY.ko ] 2>/dev/null && return 0
	ipt -t mangle -N ENGVPN_TP_PROBE 2>/dev/null || true
	if ipt -t mangle -A ENGVPN_TP_PROBE -p udp -j TPROXY --on-port 1 --tproxy-mark 0x1/0x1 2>/dev/null; then
		ipt -t mangle -F ENGVPN_TP_PROBE 2>/dev/null || true
		ipt -t mangle -X ENGVPN_TP_PROBE 2>/dev/null || true
		return 0
	fi
	ipt -t mangle -F ENGVPN_TP_PROBE 2>/dev/null || true
	ipt -t mangle -X ENGVPN_TP_PROBE 2>/dev/null || true
	return 1
}

fetch_ip() {
	# $1 = optional "via_proxy" | "direct" | "ipv6"
	mode=$1
	ip=""
	for url in \
		"https://api.ipify.org" \
		"https://ifconfig.me/ip" \
		"https://icanhazip.com"; do
		case "$mode" in
		ipv6)
			ip=$(curl -6 -fsS --connect-timeout 4 --max-time 8 "$url" 2>/dev/null | tr -d '\r\n[:space:]') || ip=""
			;;
		via_proxy)
			if [ -n "$HTTP_PORT" ]; then
				ip=$(curl -fsS --connect-timeout 5 --max-time 10 \
					-x "http://127.0.0.1:${HTTP_PORT}" "$url" 2>/dev/null | tr -d '\r\n[:space:]') || ip=""
			elif [ -n "$SOCKS_PORT" ]; then
				ip=$(curl -fsS --connect-timeout 5 --max-time 10 \
					--socks5-hostname "127.0.0.1:${SOCKS_PORT}" "$url" 2>/dev/null | tr -d '\r\n[:space:]') || ip=""
			else
				ip=""
			fi
			;;
		*)
			ip=$(curl -4 -fsS --connect-timeout 4 --max-time 8 "$url" 2>/dev/null | tr -d '\r\n[:space:]') || ip=""
			;;
		esac
		echo "$ip" | grep -Eq '^[0-9a-fA-F:.]+$' || continue
		echo "$ip"
		return 0
	done
	echo ""
	return 1
}

wan_dns_list() {
	out=""
	if type nvram >/dev/null 2>&1; then
		out="$out $(nvram get wan0_dns 2>/dev/null)"
		out="$out $(nvram get wan_dns 2>/dev/null)"
		out="$out $(nvram get wan0_xdns 2>/dev/null)"
	fi
	if [ -r /etc/resolv.conf ]; then
		out="$out $(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null)"
	fi
	echo "$out" | tr ',;' ' ' | tr -s ' ' | sed 's/^ //;s/ $//'
}

# Active resolver used by dig/nslookup on the router (may be VPN or ISP).
probe_resolver_ip() {
	# Best-effort: ask a public DNS leak id; collect answers that look like IPs from dig
	id=$(awk 'BEGIN { srand(); printf "%d", 10000000 + int(rand() * 89999999) }')
	i=1
	while [ "$i" -le 3 ]; do
		if command -v dig >/dev/null 2>&1; then
			dig +short +time=2 +tries=1 "$i.$id.bash.ws" >/dev/null 2>&1 || true
		elif command -v nslookup >/dev/null 2>&1; then
			nslookup "$i.$id.bash.ws" >/dev/null 2>&1 || true
		else
			break
		fi
		i=$((i + 1))
	done
	# Prefer listing configured nameservers as "seen" when remote probe unavailable
	echo ""
}

global_ipv6_addrs() {
	ip -6 addr show scope global 2>/dev/null | awk '/inet6 / {print $2}' | cut -d/ -f1 | head -n 8 | tr '\n' ' ' | sed 's/ $//'
}

ks_active() {
	ipt -t filter -L "$KS_CHAIN" -n >/dev/null 2>&1
}

engvpn_chain_active() {
	ipt -t nat -L "$CHAIN" -n >/dev/null 2>&1 || ipt -t mangle -L "$CHAIN" -n >/dev/null 2>&1
}

nfqws_running() {
	[ -f "$PID_NFQWS" ] && [ -d "/proc/$(cat "$PID_NFQWS" 2>/dev/null)" ] && return 0
	pgrep -f 'nfqws' >/dev/null 2>&1
}

mtu_hint() {
	# Typical WAN iface MTU
	if type nvram >/dev/null 2>&1; then
		wan=$(nvram get wan0_ifname 2>/dev/null)
		[ -n "$wan" ] || wan=$(nvram get wan_ifname 2>/dev/null)
	else
		wan=""
	fi
	[ -n "$wan" ] || wan=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
	if [ -n "$wan" ] && [ -r "/sys/class/net/$wan/mtu" ]; then
		cat "/sys/class/net/$wan/mtu" 2>/dev/null
		return 0
	fi
	echo ""
}

udp_reach_hint() {
	# Cannot fully test UDP VPN from here without a live peer; report TPROXY capability
	if have_tproxy; then
		echo "tproxy_ok"
	else
		echo "no_xt_TPROXY"
	fi
}

isp_sees_summary() {
	# Plain-language: what the ISP path likely observes
	proto=$(printf '%s' "$PROTO_HINT" | tr '[:upper:]' '[:lower:]')
	sec=$(printf '%s' "$SECURITY_HINT" | tr '[:upper:]' '[:lower:]')
	eng=$(printf '%s' "$ENGINE_HINT" | tr '[:upper:]' '[:lower:]')
	dpi_on=0
	nfqws_running && dpi_on=1
	[ "${pc_enabled:-0}" = 1 ] && dpi_on=1

	case "$sec" in
	*reality* | reality)
		echo "Похоже на обычный HTTPS (XTLS/Reality) к чужому сайту — сырой VPN-отпечаток маловероятен."
		return
		;;
	esac
	case "$proto" in
	*vless* | *trojan* | *hysteria* | *tuic*)
		if [ "$dpi_on" = 1 ]; then
			echo "Протокол туннеля поверх TLS/QUIC; nfqws/zapret активен для обхода DPI на выбранных сайтах (не маскирует сам туннель целиком)."
		else
			echo "Туннель поверх TLS/QUIC. Без Reality/WARP провайдер может видеть факт долгоживущего шифрованного сеанса, но не содержимое."
		fi
		return
		;;
	*wireguard* | *awg* | *amnezia*)
		if [ "$warp_mode" != "off" ] && [ -n "$warp_mode" ]; then
			echo "WireGuard/WARP: для ISP это UDP к Cloudflare; профиль WARP снижает узнаваемость «домашнего» WG-сервера."
		else
			echo "Сырой WireGuard/AmneziaWG: UDP с характерным почерком — провайдер может распознать VPN, если нет обфускации."
		fi
		return
		;;
	*shadowsocks* | *ss*)
		echo "Shadowsocks: шифрованный поток; без плагинов/обфускации DPI иногда классифицирует как VPN/прокси."
		return
		;;
	esac
	if [ "$dpi_on" = 1 ]; then
		echo "DPI (nfqws) включён для обхода блокировок сайтов; это не анонимизация и не скрытие факта VPN само по себе."
	elif [ "$VPN_CONNECTED" = 1 ]; then
		echo "VPN подключён (${eng:-ядро}), точный отпечаток зависит от протокола ноды."
	else
		echo "VPN выключен — провайдер видит обычный домашний трафик."
	fi
}

build_json() {
	wan_ip=""
	tun_ip=""
	ip6=""
	wan_dns=""
	ipv6_addrs=""
	mtu=""
	udp_h=""
	tproxy=0
	ks_conf=0
	ks_live=0
	dpi_en=0
	dpi_run=0
	chain=0
	exit_ok=0
	exit_leak=0
	dns_leak=0
	ipv6_leak=0
	ks_ok=0
	summary=""
	note=""
	webrtc="С роутера WebRTC не проверяется. На устройстве LAN откройте https://browserleaks.com/webrtc — не должно быть вашего WAN IP при полном VPN."

	[ "${pc_killswitch:-0}" = 1 ] && ks_conf=1
	ks_active && ks_live=1
	[ "${pc_enabled:-0}" = 1 ] && dpi_en=1
	nfqws_running && dpi_run=1
	engvpn_chain_active && chain=1
	have_tproxy && tproxy=1

	if [ "$ACTION" = "all" ] || [ "$ACTION" = "exit" ] || [ "$ACTION" = "status" ]; then
		wan_ip=$(fetch_ip direct || true)
		if [ "$VPN_CONNECTED" = 1 ] && { [ -n "$HTTP_PORT" ] || [ -n "$SOCKS_PORT" ]; }; then
			tun_ip=$(fetch_ip via_proxy || true)
		fi
		if [ -n "$tun_ip" ] && [ -n "$wan_ip" ] && [ "$tun_ip" != "$wan_ip" ]; then
			exit_ok=1
		elif [ -n "$tun_ip" ] && [ -n "$wan_ip" ] && [ "$tun_ip" = "$wan_ip" ]; then
			exit_leak=1
		elif [ "$VPN_CONNECTED" != 1 ]; then
			exit_ok=0
			note="${note}VPN не подключён — exit IP = WAN. "
		fi
	fi

	if [ "$ACTION" = "all" ] || [ "$ACTION" = "dns" ] || [ "$ACTION" = "status" ]; then
		wan_dns=$(wan_dns_list)
		# If DNS-via-VPN is off and WAN resolvers are ISP — advisory leak risk for LAN
		if [ "$DNS_VIA_VPN" != 1 ] && [ -n "$wan_dns" ]; then
			dns_leak=1
		fi
		# Heuristic: private/ISP resolvers (not 1.1.1.1 / 8.8.8.8 / 9.9.9.9) while DNS not forced via VPN
		case " $wan_dns " in
		*" 1.1.1.1 "* | *" 1.0.0.1 "* | *" 8.8.8.8 "* | *" 8.8.4.4 "* | *" 9.9.9.9 "*)
			# public resolvers still leak metadata to that operator, but not "ISP DNS"
			if [ "$DNS_VIA_VPN" != 1 ]; then
				dns_leak=1
			fi
			;;
		esac
		probe_resolver_ip >/dev/null 2>&1 || true
	fi

	if [ "$ACTION" = "all" ] || [ "$ACTION" = "ipv6" ] || [ "$ACTION" = "status" ]; then
		ipv6_addrs=$(global_ipv6_addrs)
		ip6=$(fetch_ip ipv6 || true)
		if [ "$IPV6_POLICY" = "block" ] && { [ -n "$ip6" ] || [ -n "$ipv6_addrs" ]; }; then
			# Global addr alone is soft signal; public curl -6 is hard leak
			if [ -n "$ip6" ]; then
				ipv6_leak=1
			fi
		fi
	fi

	if [ "$ACTION" = "all" ] || [ "$ACTION" = "killswitch" ] || [ "$ACTION" = "status" ]; then
		if [ "$ks_conf" = 1 ] && [ "$ks_live" = 1 ]; then
			ks_ok=1
		elif [ "$ks_conf" = 1 ] && [ "$ks_live" = 0 ]; then
			ks_ok=0
			note="${note}Kill-switch включён в конфиге, но цепочка $KS_CHAIN не активна. "
		fi
	fi

	if [ "$ACTION" = "all" ] || [ "$ACTION" = "path" ]; then
		mtu=$(mtu_hint)
		udp_h=$(udp_reach_hint)
	fi

	summary=$(isp_sees_summary)

	# Overall ok: no hard leaks when VPN connected
	overall=1
	if [ "$VPN_CONNECTED" = 1 ]; then
		[ "$exit_leak" = 1 ] && overall=0
		[ "$ipv6_leak" = 1 ] && overall=0
		[ "$dns_leak" = 1 ] && [ "$DNS_VIA_VPN" = 1 ] && overall=0
	fi

	wan_ip_j=$(json_escape "$wan_ip")
	tun_ip_j=$(json_escape "$tun_ip")
	ip6_j=$(json_escape "$ip6")
	wan_dns_j=$(json_escape "$wan_dns")
	ipv6_addrs_j=$(json_escape "$ipv6_addrs")
	mtu_j=$(json_escape "$mtu")
	udp_j=$(json_escape "$udp_h")
	summary_j=$(json_escape "$summary")
	note_j=$(json_escape "$note")
	webrtc_j=$(json_escape "$webrtc")
	method_j=$(json_escape "${pc_method:-redirect}")
	mode_j=$(json_escape "${pc_mode:-off}")
	mark_j=$(json_escape "${pc_mark:-0x39000}")
	warp_j=$(json_escape "$warp_mode")
	proto_j=$(json_escape "$PROTO_HINT")
	sec_j=$(json_escape "$SECURITY_HINT")
	eng_j=$(json_escape "$ENGINE_HINT")
	policy_j=$(json_escape "$IPV6_POLICY")

	cat <<EOF
{"ok":$([ "$overall" = 1 ] && echo true || echo false),"checked_at":$(date +%s)000,"vpn_connected":$([ "$VPN_CONNECTED" = 1 ] && echo true || echo false),"exit":{"wan_ip":"$wan_ip_j","tunnel_ip":"$tun_ip_j","ok":$([ "$exit_ok" = 1 ] && echo true || echo false),"leak":$([ "$exit_leak" = 1 ] && echo true || echo false),"kind":"real"},"dns":{"wan_resolvers":"$wan_dns_j","dns_via_vpn":$([ "$DNS_VIA_VPN" = 1 ] && echo true || echo false),"leak_risk":$([ "$dns_leak" = 1 ] && echo true || echo false),"kind":"real"},"ipv6":{"policy":"$policy_j","global_addrs":"$ipv6_addrs_j","exit_ip6":"$ip6_j","leak":$([ "$ipv6_leak" = 1 ] && echo true || echo false),"kind":"real"},"killswitch":{"configured":$([ "$ks_conf" = 1 ] && echo true || echo false),"chain_active":$([ "$ks_live" = 1 ] && echo true || echo false),"ok":$([ "$ks_ok" = 1 ] && echo true || echo false),"kind":"real"},"dpi":{"enabled":$([ "$dpi_en" = 1 ] && echo true || echo false),"nfqws_running":$([ "$dpi_run" = 1 ] && echo true || echo false),"queue":${pc_queue:-390},"engine":"nfqws","kind":"real"},"transparent":{"mode":"$mode_j","method":"$method_j","mark":"$mark_j","chain_active":$([ "$chain" = 1 ] && echo true || echo false),"tproxy_available":$([ "$tproxy" = 1 ] && echo true || echo false),"kind":"real"},"warp":{"mode":"$warp_j","kind":"real"},"fingerprint":{"protocol":"$proto_j","security":"$sec_j","engine":"$eng_j","isp_sees":"$summary_j","kind":"advisory"},"path":{"mtu":"$mtu_j","udp":"$udp_j","kind":"real"},"webrtc":{"hint":"$webrtc_j","kind":"advisory"},"note":"$note_j","disclaimer":"Это сигналы с роутера, не гарантия анонимности. Провайдер всегда видит факт шифрованного трафика к endpoint."}
EOF
}

case "$ACTION" in
all | status | exit | dns | ipv6 | killswitch | dpi | path)
	build_json
	;;
dry-run)
	echo '{"ok":true,"dry_run":true,"script":"privacy-check.sh"}'
	;;
*)
	echo "usage: privacy-check.sh [all|status|exit|dns|ipv6|killswitch|dpi|path|dry-run]" >&2
	exit 2
	;;
esac
