#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${TAILIME_VERSION:-1.0.0}"
OUT_DIR="${TAILIME_OUT_DIR:-$ROOT_DIR/dist}"
ZIP_PATH="$OUT_DIR/TailIME-${VERSION}-macos.zip"

"$ROOT_DIR/scripts/build-app.sh"

STAGE="$(mktemp -d /tmp/tailime-dist.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/TailIME-${VERSION}"
ditto "$OUT_DIR/TailIME.app" "$STAGE/TailIME-${VERSION}/TailIME.app"
cp "$ROOT_DIR/scripts/install.sh" "$STAGE/TailIME-${VERSION}/install.sh"
cp "$ROOT_DIR/README.md" "$STAGE/TailIME-${VERSION}/README.md"
cp "$ROOT_DIR/README.ko.md" "$STAGE/TailIME-${VERSION}/README.ko.md"
cp "$ROOT_DIR/LICENSE" "$STAGE/TailIME-${VERSION}/LICENSE"
chmod 755 "$STAGE/TailIME-${VERSION}/install.sh"

rm -f "$ZIP_PATH"
ditto -c -k --keepParent --norsrc "$STAGE/TailIME-${VERSION}" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$ZIP_PATH.sha256"

echo "✓ Distribution archive ready:"
echo "  $ZIP_PATH"
cat "$ZIP_PATH.sha256"
