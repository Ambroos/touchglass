#!/bin/sh
# Runs the test suite. Passes the Swift Testing macro plugin path explicitly: with only the
# Command Line Tools installed, the build system sometimes fails to find the TestingMacros
# plugin, and XCTest is not available as an alternative.
set -eu
cd "$(dirname "$0")/.."
toolchain="$(dirname "$(dirname "$(xcrun --find swift)")")"
exec swift test -Xswiftc -plugin-path -Xswiftc "$toolchain/lib/swift/host/plugins/testing" "$@"
