#!/bin/bash
# Builds Credo.app and wraps it in an installer (Credo-<version>.pkg) and a disk image.
# The installer offers a clean install: remove previous versions, optionally erase saved data,
# and install (or untick install to uninstall only).
#   ./build.sh            build, then open the installer
#   ./build.sh --no-open  build only
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Credo"
BUNDLE_ID="app.credo.macos"
VERSION="2.2.2"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
OPEN_INSTALLER=1
[[ "${1:-}" == "--no-open" ]] && OPEN_INSTALLER=0

say() { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31merror:\033[0m %s\n" "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "Run this on macOS."
command -v swift >/dev/null 2>&1 || fail "Swift not found. Install the Command Line Tools first:  xcode-select --install"
command -v pkgbuild >/dev/null 2>&1 || fail "pkgbuild not found (it ships with macOS / Command Line Tools)."
command -v productbuild >/dev/null 2>&1 || fail "productbuild not found (it ships with macOS / Command Line Tools)."

ARCH="$(uname -m)"   # arm64 on Apple Silicon (M-series)
say "Compiling $APP_NAME ($ARCH, release)…"
swift build -c release --arch "$ARCH"
BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"

BUILD="build"
ROOT="$BUILD/root"
APP="$ROOT/Applications/$APP_NAME.app"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

say "Assembling $APP_NAME.app…"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
if command -v iconutil >/dev/null 2>&1 && [[ -d Resources/AppIcon.iconset ]]; then
    iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

say "Signing (ad-hoc, for this Mac)…"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"

say "Building installer package…"
COMPONENT_PLIST="$BUILD/component.plist"
COMPONENT_ARGS=()
# Always install to /Applications (don't let Installer "relocate" to an old copy elsewhere).
# Newer macOS versions may omit the key, so set it if present, otherwise add it.
if pkgbuild --analyze --root "$ROOT" "$COMPONENT_PLIST" >/dev/null 2>&1 \
   && /usr/libexec/PlistBuddy -c "Print :0" "$COMPONENT_PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$COMPONENT_PLIST"
    COMPONENT_ARGS=(--component-plist "$COMPONENT_PLIST")
fi
chmod +x Installer/scripts/preinstall Installer/scripts/postinstall \
         Installer/cleanup-scripts/preinstall Installer/erase-scripts/preinstall
PKGS="$BUILD/pkgs"
mkdir -p "$PKGS"
# The app itself.
pkgbuild \
    --root "$ROOT" \
    ${COMPONENT_ARGS[@]+"${COMPONENT_ARGS[@]}"} \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --install-location "/" \
    --scripts Installer/scripts \
    "$PKGS/$APP_NAME-app.pkg"
# Script-only steps shown as installer options.
pkgbuild --nopayload --scripts Installer/cleanup-scripts \
    --identifier "$BUNDLE_ID.cleanup" --version "$VERSION" "$PKGS/$APP_NAME-cleanup.pkg"
pkgbuild --nopayload --scripts Installer/erase-scripts \
    --identifier "$BUNDLE_ID.erase" --version "$VERSION" "$PKGS/$APP_NAME-erase.pkg"

say "Building installer with clean-install options…"
RES="$BUILD/resources"
mkdir -p "$RES"
sed -e "s/__VERSION__/$VERSION/g" Installer/resources/welcome.html > "$RES/welcome.html"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__ARCH__/$ARCH/g" Installer/distribution.xml > "$BUILD/distribution.xml"
PKG="$BUILD/$APP_NAME-$VERSION.pkg"
productbuild \
    --distribution "$BUILD/distribution.xml" \
    --resources "$RES" \
    --package-path "$PKGS" \
    "$PKG"

say "Building disk image…"
DMG_STAGE="$BUILD/dmg"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null

# Keep ready-to-use installers next to this script, outside the build folder.
cp "$PKG" "./$APP_NAME-$VERSION.pkg"
cp "$DMG" "./$APP_NAME-$VERSION.dmg"

say "Done:"
echo "    ./$APP_NAME-$VERSION.pkg   double-click to install (clean-install options inside)"
echo "    ./$APP_NAME-$VERSION.dmg   open and drag $APP_NAME to Applications"
echo "    Quick check without installing:  $APP/Contents/MacOS/$APP_NAME --report"
if [[ $OPEN_INSTALLER -eq 1 ]]; then
    say "Opening the installer…"
    open "./$APP_NAME-$VERSION.pkg"
fi
