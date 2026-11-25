#!/bin/sh
# EngVPN Merlin user-script hooks (services-start, post-mount, firewall-start, …).
SHARE=$(cd "${0%/*}" 2>/dev/null && pwd) || exit 0
PREFIX=${SHARE%/share/engvpn}
SERVICE=$SHARE/service.sh
REPLAY=$SHARE/netfilter.sh
STATE=$PREFIX/data/netfilter/rules

SCHEDULE=$SHARE/schedule-update.sh

POWERED_OFF=$PREFIX/data/.powered-off

case "${1:-}" in
services-start)
	# Re-install schedule cru (RAM-only on Merlin). Skip panel/keepalive when
	# user explicitly powered off (engvpnd off) — stays down until engvpnd start.
	[ -x "$SCHEDULE" ] && sh "$SCHEDULE" install-cru >/dev/null 2>&1 || true
	if [ -f "$POWERED_OFF" ]; then
		:
	else
		[ -x "$SERVICE" ] && "$SERVICE" install-keepalive >/dev/null 2>&1 || true
		[ -x "$SERVICE" ] && "$SERVICE" start >/dev/null 2>&1 &
	fi
	;;
post-mount)
	case "$PREFIX/" in
	"${2:-/nonexistent}"/*)
		[ -x "$SCHEDULE" ] && sh "$SCHEDULE" install-cru >/dev/null 2>&1 || true
		if [ ! -f "$POWERED_OFF" ]; then
			[ -x "$SERVICE" ] && "$SERVICE" install-keepalive >/dev/null 2>&1 || true
			[ -x "$SERVICE" ] && "$SERVICE" start >/dev/null 2>&1 &
		fi
		;;
	esac
	;;
services-stop)
	[ -x "$SERVICE" ] && "$SERVICE" stop >/dev/null 2>&1 &
	;;
unmount)
	case "$PREFIX/" in
	"${2:-/nonexistent}"/*) [ -x "$SERVICE" ] && "$SERVICE" stop >/dev/null 2>&1 ;;
	esac
	;;
firewall-start | nat-start)
	# Re-open panel port; replay transparent rules if a state file exists.
	PORT=${ENGVPN_PORT:-8790}
	if type iptables >/dev/null 2>&1; then
		iptables -w -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null ||
			iptables -w -I INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
	fi
	if [ -x "$REPLAY" ]; then
		ENGVPN_NETFILTER_STATE="$STATE" sh "$REPLAY" replay >/dev/null 2>&1 || true
	fi
	;;
esac
exit 0
