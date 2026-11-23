#!/bin/sh
# Build EngVPN packages and publish a GitHub Release with feed assets.
#
#   ./publish-release.sh              # dry-run: build + print gh commands
#   ./publish-release.sh --push       # create/update release engvpn-$VERSION via gh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"
VERSION=$(cat VERSION)
TAG="engvpn-$VERSION"
PUSH=0
[ "${1:-}" = --push ] && PUSH=1

sh ./build-package.sh
cp -f feed/latest.release.json feed/latest.json

echo "Built:"
ls -la dist/engvpn_${VERSION}_merlin-*.tar.gz*
SIGS=""
for a in aarch64 armv7 x86_64; do
	[ -f "dist/engvpn_${VERSION}_merlin-${a}.tar.gz.minisig" ] && SIGS="$SIGS dist/engvpn_${VERSION}_merlin-${a}.tar.gz.minisig"
done

if [ "$PUSH" -ne 1 ]; then
	cat <<EOF

Dry-run. To publish:

  gh release create $TAG \\
    dist/engvpn_${VERSION}_merlin-aarch64.tar.gz \\
    dist/engvpn_${VERSION}_merlin-armv7.tar.gz \\
    dist/engvpn_${VERSION}_merlin-x86_64.tar.gz \\
    $SIGS \\
    --title "EngVPN $VERSION" \\
    --notes-file - <<'NOTES'
EngVPN Merlin open addon $VERSION (hard-parity).

Install: curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/merlin.sh | sh

Feed: engvpn/feed/latest.json (SHA-256 + Minisign).
NOTES

Then commit updated engvpn/feed/latest.json if hashes changed.
EOF
	exit 0
fi

command -v gh >/dev/null 2>&1 || {
	echo "gh CLI required for --push" >&2
	exit 1
}

ASSETS="dist/engvpn_${VERSION}_merlin-aarch64.tar.gz dist/engvpn_${VERSION}_merlin-armv7.tar.gz dist/engvpn_${VERSION}_merlin-x86_64.tar.gz $SIGS"

if gh release view "$TAG" >/dev/null 2>&1; then
	echo "Updating existing release $TAG"
	# shellcheck disable=SC2086
	gh release upload "$TAG" $ASSETS --clobber
else
	# shellcheck disable=SC2086
	gh release create "$TAG" $ASSETS \
		--title "EngVPN $VERSION" \
		--notes "EngVPN Merlin open addon ${VERSION}. Install via engvpn/merlin.sh (SHA-256 + Minisign feed)."
fi

echo "Published $TAG. Commit feed/latest.json if needed."
