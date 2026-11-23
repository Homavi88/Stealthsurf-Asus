#!/bin/sh
# EngVPN DPI — open packet mangling via bol-van/zapret nfqws (NFQUEUE).
# No stealthsurf-nfqws. Downloads a public release binary when missing.
#
#   dpi.sh start|stop|status|install|dry-run
#
# Config: $DATA_DIR/dpi.conf
#   enabled=0|1
#   queue=390
#   youtube=1|0
#   discord=1|0
#   mode=nfqws|fake
set -u

SHARE=$(cd "${0%/*}" 2>/dev/null && pwd -P) || exit 1
PREFIX=${SHARE%/share/engvpn}
DATA_DIR=${ENGVPN_DATA_DIR:-$PREFIX/data}
CONF=$DATA_DIR/dpi.conf
BIN_DIR=$DATA_DIR/bin
NFQWS=$BIN_DIR/nfqws
PIDFILE=/tmp/engvpn-nfqws.pid
LOGFILE=/tmp/engvpn-nfqws.log
CHAIN=ENGVPN_DPI
PATH=/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH

enabled=0
queue=390
youtube=1
discord=1
mode=nfqws

load_conf() {
	[ -f "$CONF" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		'' | \#*) continue ;;
		*=*)
			key=${line%%=*}
			val=${line#*=}
			case "$key" in
			enabled | queue | youtube | discord | mode) eval "$key=\$val" ;;
			esac
			;;
		esac
	done <"$CONF"
}

write_default_conf() {
	mkdir -p "$DATA_DIR"
	[ -f "$CONF" ] && return 0
	cat >"$CONF" <<EOF
enabled=0
queue=390
youtube=1
discord=1
mode=nfqws
EOF
}

ipt() {
	if iptables -w 2 -h >/dev/null 2>&1; then
		iptables -w 2 "$@"
	else
		iptables "$@"
	fi
}

arch_asset() {
	case "$(uname -m)" in
	aarch64 | arm64) echo "nfqws-aarch64" ;;
	armv7* | armv8l*) echo "nfqws-armv7" ;;
	x86_64 | amd64) echo "nfqws-x86_64" ;;
	*) echo "" ;;
	esac
}

# Prefer GitHub release of bol-van/zapret; fall back to building hint.
install_nfqws() {
	mkdir -p "$BIN_DIR"
	if [ -x "$NFQWS" ]; then
		echo "dpi: nfqws already at $NFQWS"
		return 0
	fi
	asset=$(arch_asset)
	[ -n "$asset" ] || {
		echo "dpi: unsupported arch $(uname -m)" >&2
		return 1
	}
	# Open zapret ships binaries in release archives named zapret-*-openwrt-*.tar.gz etc.
	# Also try direct community mirrors / tagged assets.
	work=/tmp/engvpn-zapret.$$
	rm -rf "$work"
	mkdir -m 700 "$work" || return 1
	url=${ENGVPN_ZAPRET_URL:-https://github.com/bol-van/zapret/releases/latest/download/zapret-v72.4.tar.gz}
	echo "dpi: downloading open zapret from $url"
	if ! curl -fsSL --retry 3 -o "$work/zapret.tgz" "$url"; then
		# Fallback: older known open release
		url2="https://github.com/bol-van/zapret/releases/download/v69.9/zapret-v69.9.tar.gz"
		curl -fsSL --retry 3 -o "$work/zapret.tgz" "$url2" || {
			echo "dpi: download failed; place nfqws at $NFQWS manually" >&2
			rm -rf "$work"
			return 1
		}
	fi
	tar -xzf "$work/zapret.tgz" -C "$work" 2>/dev/null || {
		echo "dpi: unpack failed" >&2
		rm -rf "$work"
		return 1
	}
	found=$(find "$work" -type f -name nfqws 2>/dev/null | head -n 1)
	# Arch-specific binaries often live under binaries/<arch>/
	if [ -z "$found" ]; then
		case "$(uname -m)" in
		aarch64 | arm64) found=$(find "$work" -type f -path '*/aarch64*/nfqws' 2>/dev/null | head -n 1) ;;
		armv7* | armv8l*) found=$(find "$work" -type f -path '*/arm*' -name nfqws 2>/dev/null | head -n 1) ;;
		x86_64 | amd64) found=$(find "$work" -type f \( -path '*/x86_64*/nfqws' -o -path '*/x86*/nfqws' \) 2>/dev/null | head -n 1) ;;
		esac
	fi
	if [ -z "$found" ] || [ ! -f "$found" ]; then
		echo "dpi: nfqws binary not found in archive; place it at $NFQWS" >&2
		rm -rf "$work"
		return 1
	fi
	cp -f "$found" "$NFQWS"
	chmod 755 "$NFQWS"
	rm -rf "$work"
	echo "dpi: installed $NFQWS"
}

have_nfqueue() {
	[ "${ENGVPN_SMOKE:-}" = 1 ] && return 1
	ipt -t mangle -N ENGVPN_DPI_PROBE 2>/dev/null || true
	if ipt -t mangle -A ENGVPN_DPI_PROBE -p tcp -j NFQUEUE --queue-num 1 2>/dev/null; then
		ipt -t mangle -F ENGVPN_DPI_PROBE 2>/dev/null || true
		ipt -t mangle -X ENGVPN_DPI_PROBE 2>/dev/null || true
		return 0
	fi
	ipt -t mangle -F ENGVPN_DPI_PROBE 2>/dev/null || true
	ipt -t mangle -X ENGVPN_DPI_PROBE 2>/dev/null || true
	return 1
}

flush_dpi() {
	ipt -t mangle -D POSTROUTING -j "$CHAIN" 2>/dev/null || true
	ipt -t mangle -D OUTPUT -j "$CHAIN" 2>/dev/null || true
	ipt -t mangle -F "$CHAIN" 2>/dev/null || true
	ipt -t mangle -X "$CHAIN" 2>/dev/null || true
}

stop_nfqws() {
	if [ -f "$PIDFILE" ]; then
		pid=$(cat "$PIDFILE" 2>/dev/null)
		[ -n "$pid" ] && kill "$pid" 2>/dev/null || true
		rm -f "$PIDFILE"
	fi
	pkill -f "$NFQWS" 2>/dev/null || true
}

stop_all() {
	flush_dpi
	stop_nfqws
	echo "dpi: stopped"
}

build_rules() {
	ipt -t mangle -N "$CHAIN" 2>/dev/null || ipt -t mangle -F "$CHAIN" 2>/dev/null || true
	# Mark TCP SYN / TLS ClientHello toward common DPI targets into NFQUEUE
	if [ "$youtube" = 1 ]; then
		for host in googlevideo.com youtube.com ytimg.com youtubei.googleapis.com; do
			# string match when xt_string available; otherwise broad HTTPS queue (still open/safe)
			ipt -t mangle -A "$CHAIN" -p tcp --dport 443 -m string --string "$host" --algo bm -j NFQUEUE --queue-num "$queue" 2>/dev/null || true
		done
	fi
	if [ "$discord" = 1 ]; then
		for host in discord.com discordapp.com discord.gg gateway.discord.gg; do
			ipt -t mangle -A "$CHAIN" -p tcp --dport 443 -m string --string "$host" --algo bm -j NFQUEUE --queue-num "$queue" 2>/dev/null || true
			ipt -t mangle -A "$CHAIN" -p udp --dport 443 -m string --string "$host" --algo bm -j NFQUEUE --queue-num "$queue" 2>/dev/null || true
		done
	fi
	# Fallback: if no string matches added anything useful, queue outbound HTTPS for mangling (nfqws filters)
	count=$(ipt -t mangle -L "$CHAIN" -n 2>/dev/null | wc -l | tr -d ' ')
	if [ "${count:-0}" -lt 3 ]; then
		ipt -t mangle -A "$CHAIN" -p tcp --dport 443 -m connbytes --connbytes 1:6 --connbytes-mode packets --connbytes-dir original -j NFQUEUE --queue-num "$queue" 2>/dev/null ||
			ipt -t mangle -A "$CHAIN" -p tcp --dport 443 -m conntrack --ctstate NEW -j NFQUEUE --queue-num "$queue" 2>/dev/null ||
			ipt -t mangle -A "$CHAIN" -p tcp --dport 443 -j NFQUEUE --queue-num "$queue" 2>/dev/null || true
	fi
	ipt -t mangle -C POSTROUTING -j "$CHAIN" 2>/dev/null || ipt -t mangle -I POSTROUTING 1 -j "$CHAIN"
	ipt -t mangle -C OUTPUT -j "$CHAIN" 2>/dev/null || ipt -t mangle -I OUTPUT 1 -j "$CHAIN" 2>/dev/null || true
}

start_nfqws() {
	[ -x "$NFQWS" ] || install_nfqws || return 1
	stop_nfqws
	# Classic open zapret fake TLS + disorder strategy (safe defaults)
	nohup "$NFQWS" \
		--qnum="$queue" \
		--dpi-desync=fake,disorder2 \
		--dpi-desync-ttl=1 \
		--dpi-desync-fooling=badseq \
		--dpi-desync-fake-tls=0x00000000 \
		>>"$LOGFILE" 2>&1 &
	echo $! >"$PIDFILE"
	sleep 1
	if [ -d "/proc/$(cat "$PIDFILE" 2>/dev/null)" ]; then
		echo "dpi: nfqws running pid=$(cat "$PIDFILE") queue=$queue"
		return 0
	fi
	echo "dpi: nfqws failed to stay up; see $LOGFILE" >&2
	return 1
}

apply() {
	write_default_conf
	load_conf
	if [ "$enabled" != 1 ]; then
		stop_all
		echo "dpi: enabled=0"
		return 0
	fi
	if [ "${ENGVPN_SMOKE:-}" = 1 ]; then
		echo "dpi: smoke skip live NFQUEUE"
		return 0
	fi
	if ! have_nfqueue; then
		echo "dpi: NFQUEUE unavailable on this kernel; keep routing/zapret path-probe only" >&2
		return 1
	fi
	flush_dpi
	build_rules
	start_nfqws
}

status() {
	load_conf
	running=0
	[ -f "$PIDFILE" ] && [ -d "/proc/$(cat "$PIDFILE" 2>/dev/null)" ] && running=1
	echo "enabled=$enabled queue=$queue youtube=$youtube discord=$discord nfqws=$running"
	if ipt -t mangle -L "$CHAIN" -n >/dev/null 2>&1; then
		echo "chain=active"
	else
		echo "chain=inactive"
	fi
	[ -x "$NFQWS" ] && echo "bin=$NFQWS" || echo "bin=missing"
}

dry_run() {
	write_default_conf
	load_conf
	echo "enabled=$enabled queue=$queue youtube=$youtube discord=$discord mode=$mode"
	echo "bin=$NFQWS conf=$CONF"
	if [ "${ENGVPN_SMOKE:-}" = 1 ]; then
		echo "nfqueue=skipped"
	elif have_nfqueue; then
		echo "nfqueue=yes"
	else
		echo "nfqueue=no"
	fi
}

ACTION=${1:-status}
case "$ACTION" in
start | apply) apply ;;
stop) stop_all ;;
status) status ;;
install) install_nfqws ;;
dry-run) dry_run ;;
*)
	echo "Usage: $0 start|stop|status|install|dry-run|apply" >&2
	exit 2
	;;
esac
