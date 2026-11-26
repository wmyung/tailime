#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WIN_DIR="$ROOT_DIR/windows"
VERSION="${TAILIME_VERSION:-1.1.0}"
OUT_DIR="${TAILIME_OUT_DIR:-$ROOT_DIR/dist}"
ARCH="${TAILIME_WIN_ARCH:-amd64}"
case "$ARCH" in
  amd64)
    ARCH_LABEL="x64"
    ;;
  arm64)
    ARCH_LABEL="arm64"
    ;;
  *)
    echo "ERROR: Unsupported Windows architecture '$ARCH'. TailIME requires 64-bit Windows (amd64 or arm64)." >&2
    exit 1
    ;;
esac

SETUP_EXE="$OUT_DIR/TailIME-${VERSION}-windows-${ARCH_LABEL}-setup.exe"
ZIP_PATH="$OUT_DIR/TailIME-${VERSION}-windows-${ARCH_LABEL}.zip"
EMBED_DIR="$WIN_DIR/cmd/tailime-setup/payload"
STAGE="$(mktemp -d /tmp/tailime-win.XXXXXX)"

cleanup() {
  rm -rf "$STAGE" "$EMBED_DIR"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"

echo "==> [Windows 1/4] Running Go tests & Windows cross-vet..."
(cd "$WIN_DIR" && go test -v ./... && GOOS=windows GOARCH="$ARCH" CGO_ENABLED=0 go vet ./...)

echo "==> [Windows 2/4] Cross-compiling TailIME.exe (GUI) & tailime-ctl.exe (console) for windows/${ARCH}..."
mkdir -p "$EMBED_DIR"
(
  cd "$WIN_DIR"
  GOOS=windows GOARCH="$ARCH" CGO_ENABLED=0 go build -trimpath -ldflags="-H=windowsgui -s -w" -o "$EMBED_DIR/TailIME.exe" ./cmd/tailime
  GOOS=windows GOARCH="$ARCH" CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "$EMBED_DIR/tailime-ctl.exe" ./cmd/tailime-ctl
)
cp "$ROOT_DIR/README.ko.md" "$EMBED_DIR/README.ko.md"
cp "$ROOT_DIR/README.md" "$EMBED_DIR/README.md"
cp "$ROOT_DIR/LICENSE" "$EMBED_DIR/LICENSE"

echo "==> [Windows 3/4] Building self-extracting native Windows GUI installer ($SETUP_EXE)..."
rm -f "$SETUP_EXE" "$SETUP_EXE.sha256"
(
  cd "$WIN_DIR"
  GOOS=windows GOARCH="$ARCH" CGO_ENABLED=0 go vet -tags embedpayload ./cmd/tailime-setup
  GOOS=windows GOARCH="$ARCH" CGO_ENABLED=0 go build -tags embedpayload -trimpath -ldflags="-H=windowsgui -s -w" -o "$SETUP_EXE" ./cmd/tailime-setup
)
file "$SETUP_EXE"
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$SETUP_EXE")") > "$SETUP_EXE.sha256"

echo "==> [Windows 4/4] Creating portable Windows ZIP archive ($ZIP_PATH)..."
ZIP_STAGE="$STAGE/TailIME-${VERSION}-windows-${ARCH_LABEL}"
mkdir -p "$ZIP_STAGE"
cp "$EMBED_DIR/TailIME.exe" "$ZIP_STAGE/TailIME.exe"
cp "$EMBED_DIR/tailime-ctl.exe" "$ZIP_STAGE/tailime-ctl.exe"
cp "$WIN_DIR/scripts/install.ps1" "$ZIP_STAGE/install.ps1"
cp "$WIN_DIR/scripts/uninstall.ps1" "$ZIP_STAGE/uninstall.ps1"
cp "$ROOT_DIR/README.ko.md" "$ZIP_STAGE/README.ko.md"
cp "$ROOT_DIR/README.md" "$ZIP_STAGE/README.md"
cp "$ROOT_DIR/LICENSE" "$ZIP_STAGE/LICENSE"

rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
(cd "$STAGE" && zip -r -q "$ZIP_PATH" "TailIME-${VERSION}-windows-${ARCH_LABEL}")
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$ZIP_PATH")") > "$ZIP_PATH.sha256"

echo "✓ Windows distribution artifacts ready:"
for f in "$SETUP_EXE" "$ZIP_PATH"; do
  echo "  $f"
  cat "$f.sha256"
done
