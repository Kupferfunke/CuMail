#!/bin/bash
set -euo pipefail
HELPERS_PATH="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$HELPERS_PATH"
BRIDGE_ARCH="${CURRENT_ARCH:-$(uname -m)}"
if [ "$BRIDGE_ARCH" = "undefined_arch" ]; then BRIDGE_ARCH="$(uname -m)"; fi
xcrun swiftc -swift-version 6 -O -target "$BRIDGE_ARCH-apple-macosx15.0" -sdk "$SDKROOT" \
    "$SRCROOT/Services/MailBridge/main.swift" -o "$HELPERS_PATH/MikeMailBridge"
cp "$HELPERS_PATH/MikeMailBridge" "$HELPERS_PATH/MikeMailBridgeSandboxed"
TUNNEL_PATH="$(python3 "$SRCROOT/Scripts/prepare-tunnel-client.py" "$BRIDGE_ARCH")"
cp "$TUNNEL_PATH/tunnel-client" "$HELPERS_PATH/tunnel-client"
LICENSE_PATH="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/OpenAITunnelLicenses"
mkdir -p "$LICENSE_PATH"
cp "$TUNNEL_PATH/LICENSE" "$TUNNEL_PATH/NOTICE" "$TUNNEL_PATH/"*licenses.txt "$LICENSE_PATH/"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$HELPERS_PATH/MikeMailBridge"
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none --entitlements "$SRCROOT/Config/InheritedHelper.entitlements" "$HELPERS_PATH/MikeMailBridgeSandboxed"
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none --entitlements "$SRCROOT/Config/InheritedHelper.entitlements" "$HELPERS_PATH/tunnel-client"
fi
