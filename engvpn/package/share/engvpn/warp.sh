#!/bin/sh
# EngVPN Cloudflare WARP + optional GRE backup — open path (no StealthSurf stack).
#
# WARP: register a free Cloudflare WARP WireGuard identity via the public
# API used by wgcf, then write a profile EngVPN cores can import.
# GRE: optional ip tunnel for backup transport when gre_enabled=1.
#
#   warp.sh create|status|import-file <path>|gre-up|gre-down|dry-run
set -u

SHARE=$(cd "${0%/*}" 2>/dev/null && pwd -P) || exit 1
PREFIX=${SHARE%/share/engvpn}
DATA_DIR=${ENGVPN_DATA_DIR:-$PREFIX/data}
CONF=$DATA_DIR/warp.conf
PROFILE=$DATA_DIR/warp.profile.ini
GRE_CONF=$DATA_DIR/gre.conf
PATH=/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH

mode=off
method=wireguard
gre_enabled=0
gre_remote=""
gre_local=""
gre_dev=engvpn-gre

load_conf() {
	[ -f "$CONF" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		'' | \#*) continue ;;
		*=*)
			key=${line%%=*}
			val=${line#*=}
			case "$key" in
			mode | method) eval "$key=\$val" ;;
			esac
			;;
		esac
	done <"$CONF"
	[ -f "$GRE_CONF" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		'' | \#*) continue ;;
		*=*)
			key=${line%%=*}
			val=${line#*=}
			case "$key" in
			gre_enabled | gre_remote | gre_local | gre_dev) eval "$key=\$val" ;;
			esac
			;;
		esac
	done <"$GRE_CONF"
}

# Cloudflare WARP registration (same open API as wgcf / unofficial clients).
# Requires openssl for Curve25519 keygen when available; otherwise Node helper.
b64url_to_std() {
	printf '%s' "$1" | tr '_-' '/+' | awk '{
		s=$0; while (length(s) % 4) s=s "="; print s
	}'
}

gen_wg_keys_openssl() {
	# OpenSSL 3+ can generate raw x25519 keys
	priv=$(openssl genpkey -algorithm x25519 2>/dev/null | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 -w0 2>/dev/null || openssl genpkey -algorithm x25519 2>/dev/null | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64)
	[ -n "$priv" ] || return 1
	# Derive public via openssl
	tmp=/tmp/engvpn-wg.$$
	printf '%s' "$priv" | base64 -d >"$tmp.priv.raw" 2>/dev/null || return 1
	# Prefer Node for reliable Curve25519
	rm -f "$tmp.priv.raw"
	return 1
}

gen_wg_keys_node() {
	node=$(command -v node 2>/dev/null || echo /opt/bin/node)
	[ -x "$node" ] || return 1
	"$node" -e '
const { generateKeyPairSync } = require("crypto");
const { privateKey, publicKey } = generateKeyPairSync("x25519");
const priv = privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32);
const pub = publicKey.export({ type: "spki", format: "der" }).subarray(-32);
process.stdout.write(Buffer.from(priv).toString("base64") + "\n" + Buffer.from(pub).toString("base64") + "\n");
'
}

create_profile() {
	mkdir -p "$DATA_DIR"
	keys=$(gen_wg_keys_node) || {
		echo "warp: need Node.js (x25519) to create WARP keys" >&2
		return 1
	}
	priv=$(printf '%s\n' "$keys" | sed -n '1p')
	pub=$(printf '%s\n' "$keys" | sed -n '2p')
	[ -n "$priv" ] && [ -n "$pub" ] || {
		echo "warp: keygen failed" >&2
		return 1
	}
	# Register with Cloudflare
	body=$(printf '{"key":"%s","install_id":"","fcm_token":"","tos":"%s","model":"EngVPN","serial_number":""}' "$pub" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)")
	resp=$(curl -fsS --retry 3 \
		-H 'User-Agent: okhttp/3.12.1' \
		-H 'Content-Type: application/json' \
		-d "$body" \
		https://api.cloudflareclient.com/v0a1922/reg 2>/dev/null) || {
		echo "warp: Cloudflare registration failed (network/block?)" >&2
		return 1
	}
	# Parse with node for robustness
	node=$(command -v node 2>/dev/null || echo /opt/bin/node)
	parsed=$("$node" -e '
const fs=require("fs");
const raw=fs.readFileSync(0,"utf8");
let j; try { j=JSON.parse(raw); } catch(e) { process.exit(2); }
const cfg=j.config||{};
const iface=cfg.interface||{};
const peer=(cfg.peers&&cfg.peers[0])||{};
const addr=(iface.addresses&&iface.addresses.v4)||"172.16.0.2";
const endpoint=(peer.endpoint&&peer.endpoint.host)||"engage.cloudflareclient.com";
const port=(peer.endpoint&&peer.endpoint.port)||2408;
const peerKey=peer.public_key||"";
if(!peerKey) process.exit(3);
process.stdout.write([addr, endpoint, String(port), peerKey, j.id||"", j.account&&j.account.account_type||"free"].join("\n"));
' <<EOF
$resp
EOF
	) || {
		echo "warp: unexpected Cloudflare response" >&2
		return 1
	}
	addr=$(printf '%s\n' "$parsed" | sed -n '1p')
	endpoint=$(printf '%s\n' "$parsed" | sed -n '2p')
	port=$(printf '%s\n' "$parsed" | sed -n '3p')
	peer_key=$(printf '%s\n' "$parsed" | sed -n '4p')
	cf_id=$(printf '%s\n' "$parsed" | sed -n '5p')
	acct=$(printf '%s\n' "$parsed" | sed -n '6p')

	cat >"$PROFILE" <<EOF
# EngVPN Cloudflare WARP (open registration)
# id=$cf_id account=$acct
[Interface]
PrivateKey = $priv
Address = ${addr}/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = $peer_key
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${endpoint}:${port}
EOF
	chmod 600 "$PROFILE"
	cat >"$CONF" <<EOF
mode=proxy
method=wireguard
profile=$PROFILE
id=$cf_id
account=$acct
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
	chmod 600 "$CONF"
	echo "warp: wrote $PROFILE"
	echo "profile=$PROFILE"
}

import_file() {
	src=$1
	[ -f "$src" ] || {
		echo "warp: missing $src" >&2
		return 1
	}
	mkdir -p "$DATA_DIR"
	cp -f "$src" "$PROFILE"
	chmod 600 "$PROFILE"
	cat >"$CONF" <<EOF
mode=proxy
method=wireguard
profile=$PROFILE
imported=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
	echo "warp: imported $PROFILE"
}

gre_up() {
	load_conf
	[ "$gre_enabled" = 1 ] || {
		echo "gre: gre_enabled=0"
		return 0
	}
	[ -n "$gre_remote" ] || {
		echo "gre: set gre_remote in $GRE_CONF" >&2
		return 1
	}
	[ "${ENGVPN_SMOKE:-}" = 1 ] && {
		echo "gre: smoke skip"
		return 0
	}
	ip tunnel del "$gre_dev" 2>/dev/null || true
	if [ -n "$gre_local" ]; then
		ip tunnel add "$gre_dev" mode gre remote "$gre_remote" local "$gre_local" ttl 64 2>/dev/null ||
			ip link add "$gre_dev" type gre remote "$gre_remote" local "$gre_local" 2>/dev/null || {
				echo "gre: failed to create tunnel" >&2
				return 1
			}
	else
		ip tunnel add "$gre_dev" mode gre remote "$gre_remote" ttl 64 2>/dev/null ||
			ip link add "$gre_dev" type gre remote "$gre_remote" 2>/dev/null || {
				echo "gre: failed to create tunnel" >&2
				return 1
			}
	fi
	ip link set "$gre_dev" up 2>/dev/null || true
	echo "gre: up $gre_dev → $gre_remote"
}

gre_down() {
	load_conf
	ip tunnel del "$gre_dev" 2>/dev/null || ip link del "$gre_dev" 2>/dev/null || true
	echo "gre: down"
}

status() {
	load_conf
	echo "mode=$mode method=$method"
	[ -f "$PROFILE" ] && echo "profile=$PROFILE" || echo "profile=missing"
	echo "gre_enabled=$gre_enabled gre_dev=$gre_dev gre_remote=${gre_remote:-}"
	if ip link show "$gre_dev" >/dev/null 2>&1; then
		echo "gre=up"
	else
		echo "gre=down"
	fi
}

dry_run() {
	load_conf
	echo "mode=$mode method=$method profile=$PROFILE"
	echo "gre_enabled=$gre_enabled gre_remote=${gre_remote:-} gre_local=${gre_local:-}"
	echo "cloudflare_api=https://api.cloudflareclient.com/v0a1922/reg"
}

ACTION=${1:-status}
case "$ACTION" in
create) create_profile ;;
import-file)
	shift
	import_file "${1:-}"
	;;
gre-up) gre_up ;;
gre-down) gre_down ;;
status) status ;;
dry-run) dry_run ;;
*)
	echo "Usage: $0 create|status|import-file <path>|gre-up|gre-down|dry-run" >&2
	exit 2
	;;
esac
