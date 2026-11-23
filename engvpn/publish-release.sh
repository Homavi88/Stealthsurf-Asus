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
ls -la dist/engvpn_${VERSION}_merlin-*.tar.gz

if [ "$PUSH" -ne 1 ]; then
	cat <<EOF

Dry-run. To publish:

  gh release create $TAG \\
    dist/engvpn_${VERSION}_merlin-aarch64.tar.gz \\
    dist/engvpn_${VERSION}_merlin-armv7.tar.gz \\
    dist/engvpn_${VERSION}_merlin-x86_64.tar.gz \\
    --title "EngVPN $VERSION" \\
    --notes-file - <<'NOTES'
EngVPN Merlin open addon $VERSION.

Install: curl -fsSL https://raw.githubusercontent.com/Homavi88/Stealthsurf-Asus/main/engvpn/merlin.sh | sh

Feed: engvpn/feed/latest.json (SHA-256 verified).
NOTES

Then commit updated engvpn/feed/latest.json if hashes changed.
EOF
	exit 0
fi

command -v gh >/dev/null 2>&1 || {
	echo "gh CLI required for --push" >&2
	exit 1
}

if gh release view "$TAG" >/dev/null 2>&1; then
	echo "Updating existing release $TAG"
	gh release upload "$TAG" \
		"dist/engvpn_${VERSION}_merlin-aarch64.tar.gz" \
		"dist/engvpn_${VERSION}_merlin-armv7.tar.gz" \
		"dist/engvpn_${VERSION}_merlin-x86_64.tar.gz" \
		--clobber
else
	gh release create "$TAG" \
		"dist/engvpn_${VERSION}_merlin-aarch64.tar.gz" \
		"dist/engvpn_${VERSION}_merlin-armv7.tar.gz" \
		"dist/engvpn_${VERSION}_merlin-x86_64.tar.gz" \
		--title "EngVPN $VERSION" \
		--notes "EngVPN Merlin open addon ${VERSION}. Install via engvpn/merlin.sh (SHA-256 feed)."
fi

echo "Published $TAG. Commit feed/latest.json if needed."
