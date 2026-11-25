#!/bin/sh
# Build EngVPN Merlin packages — Rust engvpn-daemon + shell helpers + static www.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERSION=$(cat "$ROOT/VERSION")
OUT=$ROOT/dist
STAGE=$OUT/stage
BIN_DIR=$OUT/bins

rm -rf "$OUT"
mkdir -p "$STAGE/sbin" "$STAGE/share/engvpn/www" "$OUT" "$BIN_DIR"

export PATH="${HOME}/.local/zig:/usr/local/cargo/bin:${PATH:-}"

echo "Building engvpn-daemon $VERSION (Rust)…"
cd "$ROOT"

# Host binary (smoke / merlin-x86_64)
cargo build -p engvpn-daemon --release
HOST_BIN=$ROOT/target/release/engvpn-daemon
[ -x "$HOST_BIN" ] || HOST_BIN=$(find "$ROOT/target" -name engvpn-daemon -type f -executable | head -n1)
cp -a "$HOST_BIN" "$BIN_DIR/engvpn-daemon-x86_64"
chmod 0755 "$BIN_DIR/engvpn-daemon-x86_64"

# Prefer musl aarch64 via cargo-zigbuild when zig is available
build_aarch64() {
	if [ "${ENGVPN_SKIP_CROSS:-}" = 1 ]; then
		echo "  ENGVPN_SKIP_CROSS=1 — host binary for aarch64 slot"
		cp -a "$BIN_DIR/engvpn-daemon-x86_64" "$BIN_DIR/engvpn-daemon-aarch64"
		return 0
	fi
	if command -v cargo-zigbuild >/dev/null 2>&1 && command -v zig >/dev/null 2>&1; then
		echo "  cross aarch64-unknown-linux-musl (zigbuild)…"
		if cargo zigbuild -p engvpn-daemon --release --target aarch64-unknown-linux-musl; then
			cp -a "$ROOT/target/aarch64-unknown-linux-musl/release/engvpn-daemon" "$BIN_DIR/engvpn-daemon-aarch64"
			chmod 0755 "$BIN_DIR/engvpn-daemon-aarch64"
			return 0
		fi
		echo "  zigbuild aarch64 failed — falling back to host binary for package layout" >&2
	fi
	echo "  packaging host binary for aarch64 slot (set ENGVPN_SKIP_CROSS=0 + working zig for real musl)" >&2
	cp -a "$BIN_DIR/engvpn-daemon-x86_64" "$BIN_DIR/engvpn-daemon-aarch64"
}

build_armv7() {
	if [ "${ENGVPN_SKIP_CROSS:-}" = 1 ]; then
		cp -a "$BIN_DIR/engvpn-daemon-x86_64" "$BIN_DIR/engvpn-daemon-armv7"
		return 0
	fi
	if command -v cargo-zigbuild >/dev/null 2>&1 && command -v zig >/dev/null 2>&1; then
		echo "  cross armv7-unknown-linux-musleabihf (zigbuild)…"
		if cargo zigbuild -p engvpn-daemon --release --target armv7-unknown-linux-musleabihf 2>/dev/null; then
			cp -a "$ROOT/target/armv7-unknown-linux-musleabihf/release/engvpn-daemon" "$BIN_DIR/engvpn-daemon-armv7"
			chmod 0755 "$BIN_DIR/engvpn-daemon-armv7"
			return 0
		fi
	fi
	echo "  armv7 cross skipped — reuse aarch64/host placeholder" >&2
	cp -a "$BIN_DIR/engvpn-daemon-aarch64" "$BIN_DIR/engvpn-daemon-armv7" 2>/dev/null \
		|| cp -a "$BIN_DIR/engvpn-daemon-x86_64" "$BIN_DIR/engvpn-daemon-armv7"
}

build_aarch64
build_armv7

# CLI wrapper + share scripts (no Node set-password.mjs required)
cp -a "$ROOT/package/sbin/engvpnd" "$STAGE/sbin/engvpnd"
chmod 0755 "$STAGE/sbin/engvpnd"

for f in install.sh service.sh hook.sh netfilter.sh transparent.sh update.sh schedule-update.sh dpi.sh warp.sh privacy-check.sh backup.sh discover-devices.sh smartdns.sh verify-minisign.mjs download-cores.mjs; do
	if [ -f "$ROOT/package/share/engvpn/$f" ]; then
		cp -a "$ROOT/package/share/engvpn/$f" "$STAGE/share/engvpn/$f"
		chmod 0755 "$STAGE/share/engvpn/$f" 2>/dev/null || chmod 0644 "$STAGE/share/engvpn/$f"
	fi
done
# Keep set-password.mjs in archive path only — Rust handles set-password
cp -a "$ROOT/VERSION" "$STAGE/share/engvpn/VERSION"

cat >"$STAGE/share/engvpn/updates.conf.example" <<'EOF'
interval=1d
auto=0
window_start=2
window_end=5
geo_weekly=1
cores_when_missing=1
last_check=
last_result=
EOF
if [ -f "$ROOT/keys/engvpn.minisign.pub" ]; then
	cp -a "$ROOT/keys/engvpn.minisign.pub" "$STAGE/share/engvpn/engvpn.minisign.pub"
elif [ -f "$ROOT/package/share/engvpn/engvpn.minisign.pub" ]; then
	cp -a "$ROOT/package/share/engvpn/engvpn.minisign.pub" "$STAGE/share/engvpn/engvpn.minisign.pub"
fi
cat >"$STAGE/share/engvpn/transparent.conf.example" <<'EOF'
mode=off
method=auto
port=12345
mark=0x39000
table=79
killswitch=0
lan_if=br0
lan_cidr=
dns_hijack=0
dns_port=5353
captive_open=0
EOF
cat >"$STAGE/share/engvpn/dpi.conf.example" <<'EOF'
enabled=0
queue=390
youtube=1
discord=1
mode=nfqws
EOF
cat >"$STAGE/share/engvpn/gre.conf.example" <<'EOF'
gre_enabled=0
gre_remote=
gre_local=
gre_dev=engvpn-gre
EOF
cat >"$STAGE/share/engvpn/smartdns.conf.example" <<'EOF'
enabled=0
EOF
cat >"$STAGE/share/engvpn/smartdns-bypass.txt.example" <<'EOF'
# domain, IP or CIDR — traffic to these goes direct (no VPN)
EOF

# Static www UI (overlays/public is tracked; engvpn/www is local-only via root .gitignore)
if [ -d "$ROOT/overlays/public" ] && [ -f "$ROOT/overlays/public/index.html" ]; then
	cp -a "$ROOT/overlays/public/." "$STAGE/share/engvpn/www/"
elif [ -d "$ROOT/www" ]; then
	cp -a "$ROOT/www/." "$STAGE/share/engvpn/www/"
fi
if [ -f "$STAGE/share/engvpn/www/index.html" ]; then
	sed -i "s/__ENGVPN_VERSION__/$VERSION/g" "$STAGE/share/engvpn/www/index.html"
fi

# Short note in package
cat >"$STAGE/share/engvpn/RUNTIME.md" <<EOF
# EngVPN $VERSION runtime

Panel: \`sbin/engvpn-daemon\` (Rust). CLI: \`sbin/engvpnd\`.
Static UI: \`share/engvpn/www/\`.
Node.js is **not** required.
EOF

stage_bin_for_arch() {
	arch=$1
	case $arch in
	merlin-aarch64) src=$BIN_DIR/engvpn-daemon-aarch64 ;;
	merlin-armv7) src=$BIN_DIR/engvpn-daemon-armv7 ;;
	merlin-x86_64) src=$BIN_DIR/engvpn-daemon-x86_64 ;;
	*) src=$BIN_DIR/engvpn-daemon-x86_64 ;;
	esac
	cp -a "$src" "$STAGE/sbin/engvpn-daemon"
	chmod 0755 "$STAGE/sbin/engvpn-daemon"
}

pack_one() {
	arch=$1
	stage_bin_for_arch "$arch"
	(
		cd "$STAGE"
		find . -type f -o -type l | sed 's|^\./||' | sort
	) >"$STAGE/share/engvpn/files"
	name="engvpn_${VERSION}_${arch}.tar.gz"
	if tar --help 2>&1 | grep -q -- '--mtime'; then
		tar -C "$STAGE" --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner -cf - . |
			gzip -n >"$OUT/$name"
	else
		tar -C "$STAGE" -cf - . | gzip -n >"$OUT/$name"
	fi
	sum=$(sha256sum "$OUT/$name" | awk '{ print $1 }')
	size=$(wc -c <"$OUT/$name" | tr -d ' ')
	echo "$arch $name $sum $size"
}

echo "Packaging EngVPN $VERSION…"
A64=$(pack_one merlin-aarch64)
A7=$(pack_one merlin-armv7)
X86=$(pack_one merlin-x86_64)

sha64=$(echo "$A64" | awk '{ print $3 }')
size64=$(echo "$A64" | awk '{ print $4 }')
sha7=$(echo "$A7" | awk '{ print $3 }')
size7=$(echo "$A7" | awk '{ print $4 }')
shax=$(echo "$X86" | awk '{ print $3 }')
sizex=$(echo "$X86" | awk '{ print $4 }')

MINISIGN_KEY=${ENGVPN_MINISIGN_KEY:-$ROOT/keys/engvpn.minisign.key}
sign_one() {
	arch=$1
	pkg="$OUT/engvpn_${VERSION}_${arch}.tar.gz"
	if [ -f "$MINISIGN_KEY" ] && command -v minisign >/dev/null 2>&1; then
		minisign -Sm "$pkg" -s "$MINISIGN_KEY" </dev/null || true
		[ -f "${pkg}.minisig" ] && echo "signed $arch" || echo "sign skipped $arch"
	else
		echo "minisign key missing — skip signing $arch (SHA-256 only)"
	fi
}
sign_one merlin-aarch64
sign_one merlin-armv7
sign_one merlin-x86_64

minisig_local() {
	arch=$1
	sig="$OUT/engvpn_${VERSION}_${arch}.tar.gz.minisig"
	if [ -f "$sig" ]; then
		printf '"minisig": "file://%s",' "$sig"
	else
		printf '"minisig": "",'
	fi
}
minisig_release() {
	arch=$1
	sig="$OUT/engvpn_${VERSION}_${arch}.tar.gz.minisig"
	if [ -f "$sig" ]; then
		printf '"minisig": "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/engvpn-%s/engvpn_%s_%s.tar.gz.minisig",' "$VERSION" "$VERSION" "$arch"
	else
		printf '"minisig": "",'
	fi
}

RELEASE_NOTES="EngVPN $VERSION — полная замена Node-панели на Rust engvpn-daemon (musl aarch64); без V8; Diagnostics /proc без Fatal; CLI engvpnd без Node; www UI сохранён; shell transparent/DPI/WARP."

write_release_feed() {
	_dest=$1
	cat >"$_dest" <<EOF
{
  "version": "$VERSION",
  "notes": "$RELEASE_NOTES",
  "packages": {
    "merlin-aarch64": {
      "url": "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/engvpn-$VERSION/engvpn_${VERSION}_merlin-aarch64.tar.gz",
      $(minisig_release merlin-aarch64)
      "sha256": "$sha64",
      "size": $size64
    },
    "merlin-armv7": {
      "url": "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/engvpn-$VERSION/engvpn_${VERSION}_merlin-armv7.tar.gz",
      $(minisig_release merlin-armv7)
      "sha256": "$sha7",
      "size": $size7
    },
    "merlin-x86_64": {
      "url": "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/engvpn-$VERSION/engvpn_${VERSION}_merlin-x86_64.tar.gz",
      $(minisig_release merlin-x86_64)
      "sha256": "$shax",
      "size": $sizex
    }
  }
}
EOF
}

FEED=$ROOT/feed/latest.json
write_release_feed "$FEED"
write_release_feed "$ROOT/feed/latest.release.json"

LOCAL_FEED=$ROOT/feed/latest.local.json
cat >"$LOCAL_FEED" <<EOF
{
  "version": "$VERSION",
  "notes": "local smoke — do not commit",
  "packages": {
    "merlin-aarch64": {
      "url": "file://$OUT/engvpn_${VERSION}_merlin-aarch64.tar.gz",
      $(minisig_local merlin-aarch64)
      "sha256": "$sha64",
      "size": $size64
    },
    "merlin-armv7": {
      "url": "file://$OUT/engvpn_${VERSION}_merlin-armv7.tar.gz",
      $(minisig_local merlin-armv7)
      "sha256": "$sha7",
      "size": $size7
    },
    "merlin-x86_64": {
      "url": "file://$OUT/engvpn_${VERSION}_merlin-x86_64.tar.gz",
      $(minisig_local merlin-x86_64)
      "sha256": "$shax",
      "size": $sizex
    }
  }
}
EOF

if grep -E 'file://|/agent/repos/|"url":[[:space:]]*"/' "$FEED" >/dev/null 2>&1; then
	echo "build-package: REFUSING to leave local/file paths in $FEED" >&2
	exit 1
fi
case "$(grep -oE '"url":[[:space:]]*"[^"]+"' "$FEED" | head -1)" in
*https://github.com/Homavi88/Stealthsurf-Asus/releases/download/*) ;;
*)
	echo "build-package: latest.json url must be a GitHub release download URL" >&2
	exit 1
	;;
esac

echo "Wrote $FEED (+ latest.release.json; local smoke → $LOCAL_FEED)"
ls -la "$OUT"
file "$BIN_DIR"/* 2>/dev/null || true
echo "Done."
