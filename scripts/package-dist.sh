#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${TAILIME_VERSION:-1.1.0}"
OUT_DIR="${TAILIME_OUT_DIR:-$ROOT_DIR/dist}"
ZIP_PATH="$OUT_DIR/TailIME-${VERSION}-macos.zip"
DMG_PATH="$OUT_DIR/TailIME-${VERSION}-macos.dmg"
PKG_PATH="$OUT_DIR/TailIME-${VERSION}-macos.pkg"
PKG_SIGN_IDENTITY="${PKG_CODESIGN_IDENTITY:-}"

"$ROOT_DIR/scripts/build-app.sh"

STAGE="$(mktemp -d /tmp/tailime-dist.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

# 1. macOS Portable ZIP (preserves symlinks & code signature via ditto)
echo "==> [macOS 1/3] Creating ZIP archive..."
ZIP_STAGE="$STAGE/zip/TailIME-${VERSION}"
mkdir -p "$ZIP_STAGE"
ditto "$OUT_DIR/TailIME.app" "$ZIP_STAGE/TailIME.app"
cp "$ROOT_DIR/scripts/install.sh" "$ZIP_STAGE/install.sh"
cp "$ROOT_DIR/README.md" "$ZIP_STAGE/README.md"
cp "$ROOT_DIR/README.ko.md" "$ZIP_STAGE/README.ko.md"
cp "$ROOT_DIR/LICENSE" "$ZIP_STAGE/LICENSE"
chmod 755 "$ZIP_STAGE/install.sh"

rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
ditto -c -k --keepParent --norsrc "$ZIP_STAGE" "$ZIP_PATH"
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$ZIP_PATH")") > "$ZIP_PATH.sha256"

# 2. macOS Drag-and-Drop DMG Installer
echo "==> [macOS 2/3] Creating DMG disk image..."
DMG_STAGE="$STAGE/dmg"
mkdir -p "$DMG_STAGE"
ditto "$OUT_DIR/TailIME.app" "$DMG_STAGE/TailIME.app"
ln -s /Applications "$DMG_STAGE/Applications"
cp "$ROOT_DIR/scripts/install.sh" "$DMG_STAGE/install.sh"
cp "$ROOT_DIR/README.ko.md" "$DMG_STAGE/README.ko.md"
cp "$ROOT_DIR/README.md" "$DMG_STAGE/README.md"
cp "$ROOT_DIR/LICENSE" "$DMG_STAGE/LICENSE"
chmod 755 "$DMG_STAGE/install.sh"

rm -f "$DMG_PATH" "$DMG_PATH.sha256"
hdiutil create -volname "TailIME ${VERSION}" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
hdiutil verify "$DMG_PATH" >/dev/null
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG_PATH")") > "$DMG_PATH.sha256"

# 3. macOS Native PKG Installer (non-relocatable -> ALWAYS /Applications/TailIME.app)
echo "==> [macOS 3/3] Creating PKG installer..."
PKG_ROOT="$STAGE/pkg-root"
PKG_SCRIPTS="$STAGE/pkg-scripts"
COMPONENT_PKG="$STAGE/TailIME-component.pkg"
COMPONENT_PLIST="$STAGE/components.plist"
DIST_XML="$STAGE/distribution.xml"
mkdir -p "$PKG_ROOT/Applications" "$PKG_SCRIPTS"
ditto "$OUT_DIR/TailIME.app" "$PKG_ROOT/Applications/TailIME.app"

cat > "$PKG_SCRIPTS/preinstall" <<'PREEOF'
#!/bin/bash
# Gracefully stop the active console user's TailIME instance before replacing /Applications/TailIME.app
CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null || true)"
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then
  if pgrep -u "$CONSOLE_USER" -x TailIME >/dev/null 2>&1; then
    pkill -u "$CONSOLE_USER" -x TailIME || true
    sleep 0.5
  fi
fi
exit 0
PREEOF
chmod 755 "$PKG_SCRIPTS/preinstall"

cat > "$PKG_SCRIPTS/postinstall" <<'POSTEOF'
#!/bin/bash
APP_DST="/Applications/TailIME.app"
if [[ -d "$APP_DST" ]]; then
  xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true
  mkdir -p /usr/local/bin 2>/dev/null || true
  if [[ -d /usr/local/bin && -w /usr/local/bin ]]; then
    ln -sfn "$APP_DST/Contents/Helpers/tailime-ctl" /usr/local/bin/tailime-ctl 2>/dev/null || true
  fi
  # Launch TailIME as the active GUI console user (never as root)
  CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null || true)"
  if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then
    CONSOLE_UID="$(id -u "$CONSOLE_USER" 2>/dev/null || true)"
    if [[ -n "$CONSOLE_UID" ]]; then
      launchctl asuser "$CONSOLE_UID" /usr/bin/open -a "$APP_DST" >/dev/null 2>&1 || true
    fi
  fi
fi
exit 0
POSTEOF
chmod 755 "$PKG_SCRIPTS/postinstall"

# Disable bundle relocation so macOS Installer NEVER upgrades a stray build copy outside /Applications!
pkgbuild --analyze --root "$PKG_ROOT" "$COMPONENT_PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c "Set :0:BundleHasStrictIdentifier true" "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c "Set :0:BundleIsVersionChecked false" "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c "Set :0:BundleOverwriteAction upgrade" "$COMPONENT_PLIST"

pkgbuild \
  --root "$PKG_ROOT" \
  --component-plist "$COMPONENT_PLIST" \
  --scripts "$PKG_SCRIPTS" \
  --identifier "com.tailime.app.pkg" \
  --version "$VERSION" \
  --install-location "/" \
  "$COMPONENT_PKG" >/dev/null

cat > "$DIST_XML" <<DISTEOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>TailIME ${VERSION}</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <choices-outline>
        <line choice="default">
            <line choice="com.tailime.app.pkg"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="com.tailime.app.pkg" visible="false">
        <pkg-ref id="com.tailime.app.pkg"/>
    </choice>
    <pkg-ref id="com.tailime.app.pkg" version="${VERSION}" onConclusion="none">TailIME-component.pkg</pkg-ref>
</installer-gui-script>
DISTEOF

rm -f "$PKG_PATH" "$PKG_PATH.sha256"
if [[ -n "$PKG_SIGN_IDENTITY" ]]; then
  productbuild --distribution "$DIST_XML" --package-path "$STAGE" --sign "$PKG_SIGN_IDENTITY" "$PKG_PATH" >/dev/null
else
  productbuild --distribution "$DIST_XML" --package-path "$STAGE" "$PKG_PATH" >/dev/null
fi
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$PKG_PATH")") > "$PKG_PATH.sha256"

echo "✓ macOS distribution artifacts ready:"
for f in "$PKG_PATH" "$DMG_PATH" "$ZIP_PATH"; do
  echo "  $f"
  cat "$f.sha256"
done
