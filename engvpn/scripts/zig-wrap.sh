#!/bin/sh
# Install a PATH-first `zig` that strips rustc's --fix-cortex-a53-843419
# (zig ld rejects it as of 0.15). Used by cargo-zigbuild for aarch64-musl.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WRAP_DIR=${ENGVPN_ZIG_WRAP_DIR:-$ROOT/.zig-wrap}
REAL_ZIG=${ENGVPN_ZIG_REAL:-}

find_zig() {
	if [ -n "$REAL_ZIG" ] && [ -x "$REAL_ZIG" ]; then
		printf '%s\n' "$REAL_ZIG"
		return 0
	fi
	# Prefer known installs over an already-wrapped zig on PATH
	for c in \
		"$HOME/.local/zig15/zig" \
		"$HOME/.local/zig-new/zig" \
		"$HOME/.local/zig/zig" \
		/usr/local/bin/zig \
		/opt/zig/zig; do
		if [ -x "$c" ]; then
			printf '%s\n' "$c"
			return 0
		fi
	done
	# PATH zig — skip our own wrap dir
	_old=$PATH
	PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "$WRAP_DIR" | tr '\n' ':' | sed 's/:$//')
	export PATH
	if command -v zig >/dev/null 2>&1; then
		command -v zig
		PATH=$_old
		export PATH
		return 0
	fi
	PATH=$_old
	export PATH
	return 1
}

REAL=$(find_zig) || {
	echo "zig-wrap: zig not found (install Zig ≥0.13 for aarch64-musl)" >&2
	exit 1
}

mkdir -p "$WRAP_DIR"
cat >"$WRAP_DIR/zig" <<EOF
#!/bin/sh
REAL="$REAL"
n=0
for a in "\$@"; do
  case "\$a" in
    -Wl,--fix-cortex-a53-843419|--fix-cortex-a53-843419) continue ;;
  esac
  n=\$((n+1))
  eval "a\$n=\\\$a"
done
set --
i=1
while [ "\$i" -le "\$n" ]; do
  eval "set -- \\"\\\$@\\" \\"\\\$a\$i\\""
  i=\$((i+1))
done
exec "\$REAL" "\$@"
EOF
chmod 0755 "$WRAP_DIR/zig"

# Export for callers: prepend wrap dir
printf '%s\n' "$WRAP_DIR"
