#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
# CLT 6.4 does not discover TestingMacros when AppKit's testing overlay is imported.
# Use the installed toolchain's plugin; nothing is downloaded or installed.
SWIFT_BIN="$(dirname "$(xcrun --find swiftc)")"
TEST_PLUGIN="$SWIFT_BIN/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$TEST_PLUGIN" ]; then
    swift test -Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN"
else
    swift test
fi
