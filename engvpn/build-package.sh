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

export PATH="${HOME}/.local/zig15:${HOME}/.local/zig-new:${HOME}/.local/zig:/usr/local/cargo/bin:${PATH:-}"

# Never ship host (x86_64) binary inside merlin-aarch64 / merlin-armv7.
# ENGVPN_SKIP_CROSS=1 → only build merlin-x86_64 (smoke); release feed unchanged.
SKIP_CROSS=${ENGVPN_SKIP_CROSS:-0}

echo "Building engvpn-daemon $VERSION (Rust)…"
cd "$ROOT"

assert_elf_machine() {
	_bin=$1
	_want=$2 # AArch64 | ARM | X86-64
	_info=$(file -b "$_bin" 2>/dev/null || true)
	_info_lc=$(printf '%s' "$_info" | tr 'A-Z' 'a-z')
	case "$_want" in
	AArch64)
		case "$_info_lc" in *aarch64*) return 0 ;; esac
		;;
	ARM)
		# 32-bit ARM (not aarch64)
		case "$_info_lc" in
		*aarch64*) ;;
		*", arm,"* | *" arm,"* | *"arm,"* | *eabi5*) return 0 ;;
		esac
		;;
	X86-64 | x86_64)
		case "$_info_lc" in *x86-64* | *x86_64*) return 0 ;; esac
		;;
	esac
	if command -v readelf >/dev/null 2>&1; then
		_mach=$(readelf -h "$_bin" 2>/dev/null | awk -F: '/Machine:/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')
		case "$_want" in
		AArch64) [ "$_mach" = "AArch64" ] && return 0 ;;
		ARM) [ "$_mach" = "ARM" ] && return 0 ;;
		X86-64 | x86_64)
			case "$_mach" in *X86-64* | *x86-64*) return 0 ;; esac
			;;
		esac
	fi
	echo "assert_elf_machine: $_bin is not $_want — got: $_info" >&2
	return 1
}

# Host binary (smoke / merlin-x86_64)
cargo build -p engvpn-daemon --release
HOST_BIN=$ROOT/target/release/engvpn-daemon
[ -x "$HOST_BIN" ] || HOST_BIN=$(find "$ROOT/target" -name engvpn-daemon -type f -executable | head -n1)
cp -a "$HOST_BIN" "$BIN_DIR/engvpn-daemon-x86_64"
chmod 0755 "$BIN_DIR/engvpn-daemon-x86_64"

ensure_zig_wrap() {
	_wrap_dir=
	_wrap_dir=$(sh "$ROOT/scripts/zig-wrap.sh") || return 1
	export PATH="$_wrap_dir:$PATH"
	command -v zig >/dev/null 2>&1 || return 1
	command -v cargo-zigbuild >/dev/null 2>&1 || cargo install --locked cargo-zigbuild --version 0.20.1
	rustup target add aarch64-unknown-linux-musl >/dev/null 2>&1 || true
	return 0
}

build_aarch64() {
	# Prefer static musl (Merlin / Entware friendly)
	if ensure_zig_wrap; then
		echo "  cross aarch64-unknown-linux-musl (cargo-zigbuild + zig wrap)…"
		rm -rf "${HOME}/.cache/cargo-zigbuild" 2>/dev/null || true
		if cargo zigbuild -p engvpn-daemon --release --target aarch64-unknown-linux-musl; then
			cp -a "$ROOT/target/aarch64-unknown-linux-musl/release/engvpn-daemon" "$BIN_DIR/engvpn-daemon-aarch64"
			chmod 0755 "$BIN_DIR/engvpn-daemon-aarch64"
			assert_elf_machine "$BIN_DIR/engvpn-daemon-aarch64" "AArch64" || return 1
			file "$BIN_DIR/engvpn-daemon-aarch64"
			return 0
		fi
		echo "  zigbuild aarch64-musl failed" >&2
	else
		echo "  zig / cargo-zigbuild not available for musl" >&2
	fi
	# Fallback: aarch64-gnu (dynamically linked) — still real aarch64, never host
	if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
		echo "  cross aarch64-unknown-linux-gnu (gcc)…"
		rustup target add aarch64-unknown-linux-gnu >/dev/null 2>&1 || true
		export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
		if cargo build -p engvpn-daemon --release --target aarch64-unknown-linux-gnu; then
			cp -a "$ROOT/target/aarch64-unknown-linux-gnu/release/engvpn-daemon" "$BIN_DIR/engvpn-daemon-aarch64"
			chmod 0755 "$BIN_DIR/engvpn-daemon-aarch64"
			assert_elf_machine "$BIN_DIR/engvpn-daemon-aarch64" "AArch64" || return 1
			echo "  note: aarch64-gnu (glibc) — prefer musl static for Merlin when zig works" >&2
			file "$BIN_DIR/engvpn-daemon-aarch64"
			return 0
		fi
	fi
	echo "FATAL: cannot cross-compile engvpn-daemon for aarch64 (musl or gnu)." >&2
	echo "  Install Zig (≥0.13) + cargo-zigbuild, or gcc-aarch64-linux-gnu." >&2
	echo "  Refusing to put host binary into merlin-aarch64.tar.gz." >&2
	return 1
}

build_armv7() {
	if ensure_zig_wrap; then
		echo "  cross armv7-unknown-linux-musleabihf (zigbuild)…"
		rustup target add armv7-unknown-linux-musleabihf >/dev/null 2>&1 || true
		if cargo zigbuild -p engvpn-daemon --release --target armv7-unknown-linux-musleabihf; then
			cp -a "$ROOT/target/armv7-unknown-linux-musleabihf/release/engvpn-daemon" "$BIN_DIR/engvpn-daemon-armv7"
			chmod 0755 "$BIN_DIR/engvpn-daemon-armv7"
			assert_elf_machine "$BIN_DIR/engvpn-daemon-armv7" "ARM" || return 1
			return 0
		fi
	fi
	echo "  armv7 cross failed — not packaging host arch as armv7" >&2
	return 1
}

PACK_AARCH64=1
PACK_ARMV7=1
if [ "$SKIP_CROSS" = 1 ]; then
	echo "ENGVPN_SKIP_CROSS=1 — packaging merlin-x86_64 only (smoke); no aarch64/armv7 tarballs"
	PACK_AARCH64=0
	PACK_ARMV7=0
else
	build_aarch64 || exit 1
	if ! build_armv7; then
		echo "WARN: skipping merlin-armv7 package (cross failed); aarch64 is required and built" >&2
		PACK_ARMV7=0
	fi
fi

# CLI wrapper + share scripts (no Node set-password.mjs required)
cp -a "$ROOT/package/sbin/engvpnd" "$STAGE/sbin/engvpnd"
chmod 0755 "$STAGE/sbin/engvpnd"

for f in install.sh service.sh hook.sh netfilter.sh transparent.sh update.sh schedule-update.sh dpi.sh warp.sh privacy-check.sh backup.sh discover-devices.sh smartdns.sh verify-minisign.mjs download-cores.sh; do
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
X86=$(pack_one merlin-x86_64)
shax=$(echo "$X86" | awk '{ print $3 }')
sizex=$(echo "$X86" | awk '{ print $4 }')

sha64=; size64=0; sha7=; size7=0
A64=; A7=
if [ "$PACK_AARCH64" = 1 ]; then
	# Guard: refuse wrong-arch binary in Merlin aarch64 package
	assert_elf_machine "$BIN_DIR/engvpn-daemon-aarch64" "AArch64" || exit 1
	A64=$(pack_one merlin-aarch64)
	sha64=$(echo "$A64" | awk '{ print $3 }')
	size64=$(echo "$A64" | awk '{ print $4 }')
fi
if [ "$PACK_ARMV7" = 1 ]; then
	assert_elf_machine "$BIN_DIR/engvpn-daemon-armv7" "ARM" || exit 1
	A7=$(pack_one merlin-armv7)
	sha7=$(echo "$A7" | awk '{ print $3 }')
	size7=$(echo "$A7" | awk '{ print $4 }')
fi

MINISIGN_KEY=${ENGVPN_MINISIGN_KEY:-$ROOT/keys/engvpn.minisign.key}
sign_one() {
	arch=$1
	pkg="$OUT/engvpn_${VERSION}_${arch}.tar.gz"
	[ -f "$pkg" ] || return 0
	if [ -f "$MINISIGN_KEY" ] && command -v minisign >/dev/null 2>&1; then
		minisign -Sm "$pkg" -s "$MINISIGN_KEY" </dev/null || true
		[ -f "${pkg}.minisig" ] && echo "signed $arch" || echo "sign skipped $arch"
	else
		echo "minisign key missing — skip signing $arch (SHA-256 only)"
	fi
}
[ "$PACK_AARCH64" = 1 ] && sign_one merlin-aarch64
[ "$PACK_ARMV7" = 1 ] && sign_one merlin-armv7
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

RELEASE_NOTES="EngVPN $VERSION — BusyBox zip unpack for xray/ferrum (gzip-wrap, без unzip/python3); Safari: menu без Array.at + округление ЦП; Rust engvpn-daemon musl aarch64."

FEED=$ROOT/feed/latest.json
LOCAL_FEED=$ROOT/feed/latest.local.json

if [ "$PACK_AARCH64" = 1 ]; then
	# Full release packaging — require real aarch64 SHA in feed
	[ -n "$sha64" ] || {
		echo "build-package: missing aarch64 sha256" >&2
		exit 1
	}
	# armv7 optional: reuse aarch64 entry omitted if not built
	_armv7_block=
	if [ "$PACK_ARMV7" = 1 ] && [ -n "$sha7" ]; then
		_armv7_block=$(
			cat <<EOF
    "merlin-armv7": {
      "url": "https://github.com/Homavi88/Stealthsurf-Asus/releases/download/engvpn-$VERSION/engvpn_${VERSION}_merlin-armv7.tar.gz",
      $(minisig_release merlin-armv7)
      "sha256": "$sha7",
      "size": $size7
    },
EOF
		)
	fi
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
$_armv7_block
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
	write_release_feed "$FEED"
	write_release_feed "$ROOT/feed/latest.release.json"

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
	echo "Wrote $FEED (+ latest.release.json)"
else
	echo "ENGVPN_SKIP_CROSS=1 — not updating $FEED (release aarch64 hashes stay as previously published)"
fi

# Local smoke feed (x86 always; aarch64 only when packaged)
{
	printf '{\n  "version": "%s",\n  "notes": "local smoke — do not commit",\n  "packages": {\n' "$VERSION"
	if [ "$PACK_AARCH64" = 1 ]; then
		printf '    "merlin-aarch64": {\n      "url": "file://%s/engvpn_%s_merlin-aarch64.tar.gz",\n      %s\n      "sha256": "%s",\n      "size": %s\n    },\n' \
			"$OUT" "$VERSION" "$(minisig_local merlin-aarch64)" "$sha64" "$size64"
	fi
	if [ "$PACK_ARMV7" = 1 ]; then
		printf '    "merlin-armv7": {\n      "url": "file://%s/engvpn_%s_merlin-armv7.tar.gz",\n      %s\n      "sha256": "%s",\n      "size": %s\n    },\n' \
			"$OUT" "$VERSION" "$(minisig_local merlin-armv7)" "$sha7" "$size7"
	fi
	printf '    "merlin-x86_64": {\n      "url": "file://%s/engvpn_%s_merlin-x86_64.tar.gz",\n      %s\n      "sha256": "%s",\n      "size": %s\n    }\n  }\n}\n' \
		"$OUT" "$VERSION" "$(minisig_local merlin-x86_64)" "$shax" "$sizex"
} >"$LOCAL_FEED"

ls -la "$OUT"
file "$BIN_DIR"/* 2>/dev/null || true
# Final gate for Merlin package
if [ -f "$OUT/engvpn_${VERSION}_merlin-aarch64.tar.gz" ]; then
	tmpd=$(mktemp -d)
	# tarball entries are ./sbin/...
	tar -xzf "$OUT/engvpn_${VERSION}_merlin-aarch64.tar.gz" -C "$tmpd"
	assert_elf_machine "$tmpd/sbin/engvpn-daemon" "AArch64" || {
		echo "FATAL: merlin-aarch64.tar.gz does not contain an AArch64 engvpn-daemon" >&2
		rm -rf "$tmpd"
		exit 1
	}
	rm -rf "$tmpd"
	echo "Verified merlin-aarch64.tar.gz → AArch64 engvpn-daemon"
fi
echo "Done."
