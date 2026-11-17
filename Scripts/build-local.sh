#!/bin/bash
# Native local development build. Resolves the pinned SQLCipher package on first build.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
BUILD_CONFIGURATION="${CUMAIL_BUILD_CONFIGURATION:-debug}"
case "$BUILD_CONFIGURATION" in debug|release) ;; *) exit 2 ;; esac
swift build -c "$BUILD_CONFIGURATION"
BIN_DIR="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
mkdir -p "$PROJECT_ROOT/build"
STAGING_ROOT="$(mktemp -d "$PROJECT_ROOT/build/.local-build.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP_PATH="$STAGING_ROOT/CuMail.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Frameworks"
cp "$BIN_DIR/MikeMailHub" "$APP_PATH/Contents/MacOS/MikeMailHub"
mkdir -p "$APP_PATH/Contents/Helpers"
cp "$BIN_DIR/MikeMailBridge" "$APP_PATH/Contents/Helpers/MikeMailBridge"
cp "$BIN_DIR/MikeMailBridge" "$APP_PATH/Contents/Helpers/MikeMailBridgeSandboxed"
TUNNEL_PATH="$(python3 Scripts/prepare-tunnel-client.py)"
cp "$TUNNEL_PATH/tunnel-client" "$APP_PATH/Contents/Helpers/tunnel-client"
mkdir -p "$APP_PATH/Contents/Resources/OpenAITunnelLicenses"
cp "$TUNNEL_PATH/LICENSE" "$TUNNEL_PATH/NOTICE" "$TUNNEL_PATH/"*licenses.txt "$APP_PATH/Contents/Resources/OpenAITunnelLicenses/"
python3 Scripts/configure-google.py --output "$APP_PATH/Contents/Info.plist"
cp App/Resources/AppIcon.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
for RESOURCE in "$BIN_DIR"/*.bundle; do
    [ -d "$RESOURCE" ] || continue
    ditto "$RESOURCE" "$APP_PATH/Contents/Resources/$(basename "$RESOURCE")"
done
if [ -d "$BIN_DIR/PackageFrameworks" ]; then
    for FRAMEWORK in "$BIN_DIR/PackageFrameworks"/*.framework; do
        [ -d "$FRAMEWORK" ] || continue
        ditto "$FRAMEWORK" "$APP_PATH/Contents/Frameworks/$(basename "$FRAMEWORK")"
    done
fi
# SQLCipher is supplied as a dynamic binary framework in the product directory.
if [ -d "$BIN_DIR/SQLCipher.framework" ]; then
    ditto "$BIN_DIR/SQLCipher.framework" "$APP_PATH/Contents/Frameworks/SQLCipher.framework"
fi
# Keep the certificate for client authentication and copy the Keychain owner
# byte-identically across updates. The signing key stays in Keychain.
SIGNING_IDENTITY="$(python3 Scripts/local-signing.py)"
# External stdio clients are not children of the sandboxed mail app. Give
# their byte-only adapter a normal signature; the app-owned twin inherits
# the app sandbox. Both are built from exactly the same source.
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_PATH/Contents/Helpers/MikeMailBridge"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements Config/InheritedHelper.entitlements "$APP_PATH/Contents/Helpers/MikeMailBridgeSandboxed"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements Config/InheritedHelper.entitlements "$APP_PATH/Contents/Helpers/tunnel-client"
KEYCHAIN_SERVICE="$(python3 Scripts/build-keychain-service.py "$SIGNING_IDENTITY")"
mkdir -p "$APP_PATH/Contents/XPCServices"
ditto "$KEYCHAIN_SERVICE" "$APP_PATH/Contents/XPCServices/MikeMailKeychain.xpc"
/usr/libexec/PlistBuddy -c "Add :MMHKeychainCertificateSHA1 string $SIGNING_IDENTITY" "$APP_PATH/Contents/Info.plist"
for FRAMEWORK in "$APP_PATH/Contents/Frameworks"/*.framework; do
    [ -d "$FRAMEWORK" ] || continue
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$FRAMEWORK"
done
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements Config/MikeMailHub.entitlements "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
# Publish only a complete verified bundle. A signing prompt/failure must leave
# the installed development app intact. Roll back the rename if publication fails.
python3 - "$APP_PATH" "$PROJECT_ROOT/build/CuMail.app" <<'PY'
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
previous = source.parent / 'Previous.app'
if destination.exists():
    destination.rename(previous)
try:
    source.rename(destination)
except BaseException:
    if previous.exists():
        previous.rename(destination)
    raise
PY
# Refresh this bundle's declared URL schemes after the atomic replacement.
# This registers only our app; it does not open a URL or reset system defaults.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ] && [ ! -d /Applications/CuMail.app ]; then
    "$LSREGISTER" -f "$PROJECT_ROOT/build/CuMail.app"
fi
printf '\nLocal app: %s\n' "$PROJECT_ROOT/build/CuMail.app"
