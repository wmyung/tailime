#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="TailIME"
BUNDLE_ID="com.tailime.app"
VERSION="${TAILIME_VERSION:-1.1.0}"
BUILD_NUMBER="${TAILIME_BUILD_NUMBER:-4}"
OUT_DIR="${TAILIME_OUT_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
UNIVERSAL="${TAILIME_UNIVERSAL:-1}"

echo "==> [1/5] Running unit & integration tests (swift run tailime-test)..."
swift run tailime-test

echo "==> [2/5] Building release binaries..."
STAGE_BIN="$(mktemp -d /tmp/tailime-bin.XXXXXX)"
TMP_ICON_DIR=""
trap 'rm -rf "$STAGE_BIN" ${TMP_ICON_DIR:+"$TMP_ICON_DIR"}' EXIT
BUILD_FLAGS=(-c release -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR/Sources=Sources" -Xcc "-ffile-prefix-map=$ROOT_DIR/Sources=Sources")
if [[ "$UNIVERSAL" == "1" ]]; then
  swift build "${BUILD_FLAGS[@]}" --triple arm64-apple-macosx13.0 --product TailIME
  swift build "${BUILD_FLAGS[@]}" --triple arm64-apple-macosx13.0 --product tailime-ctl
  ARM_DIR="$(swift build "${BUILD_FLAGS[@]}" --triple arm64-apple-macosx13.0 --show-bin-path)"

  swift build "${BUILD_FLAGS[@]}" --triple x86_64-apple-macosx13.0 --product TailIME
  swift build "${BUILD_FLAGS[@]}" --triple x86_64-apple-macosx13.0 --product tailime-ctl
  X86_DIR="$(swift build "${BUILD_FLAGS[@]}" --triple x86_64-apple-macosx13.0 --show-bin-path)"

  lipo -create "$ARM_DIR/TailIME" "$X86_DIR/TailIME" -output "$STAGE_BIN/TailIME"
  lipo -create "$ARM_DIR/tailime-ctl" "$X86_DIR/tailime-ctl" -output "$STAGE_BIN/tailime-ctl"
  MAIN_BIN="$STAGE_BIN/TailIME"
  CLI_BIN="$STAGE_BIN/tailime-ctl"
else
  swift build "${BUILD_FLAGS[@]}" --product TailIME
  swift build "${BUILD_FLAGS[@]}" --product tailime-ctl
  BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
  MAIN_BIN="$BIN_DIR/TailIME"
  CLI_BIN="$BIN_DIR/tailime-ctl"
fi
[[ -x "$MAIN_BIN" ]] || { echo "Missing main binary: $MAIN_BIN" >&2; exit 1; }
[[ -x "$CLI_BIN" ]]  || { echo "Missing CLI binary: $CLI_BIN" >&2; exit 1; }

echo "==> [3/5] Assembling $APP_BUNDLE ..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Helpers" "$APP_BUNDLE/Contents/Resources"

cp "$MAIN_BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$CLI_BIN"  "$APP_BUNDLE/Contents/Helpers/tailime-ctl"
strip -S "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "$APP_BUNDLE/Contents/Helpers/tailime-ctl"
chmod 755 "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "$APP_BUNDLE/Contents/Helpers/tailime-ctl"

# Generate AppIcon.icns
TMP_ICON_DIR="$(mktemp -d /tmp/tailime-icon.XXXXXX)"
swift "$ROOT_DIR/scripts/generate-icon.swift" "$TMP_ICON_DIR/AppIcon.iconset"
iconutil -c icns "$TMP_ICON_DIR/AppIcon.iconset" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ko</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Tailscale 망의 다른 Mac과 한영 입력 상태를 암호화 동기화하기 위해 네트워크 접근이 필요합니다.</string>
</dict>
</plist>
EOF

echo "==> [4/5] Code signing ($SIGN_IDENTITY)..."
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - --identifier "$BUNDLE_ID.cli" "$APP_BUNDLE/Contents/Helpers/tailime-ctl"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
else
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none --identifier "$BUNDLE_ID.cli" "$APP_BUNDLE/Contents/Helpers/tailime-ctl"
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none --identifier "$BUNDLE_ID" "$APP_BUNDLE"
fi

echo "==> [5/5] Verifying bundle signature & architectures..."
codesign --verify --deep --strict "$APP_BUNDLE"
lipo -info "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
echo "✓ Built: $APP_BUNDLE"
