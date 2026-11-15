#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ] || ! command -v xcrun >/dev/null 2>&1; then
    echo 'BLOCKED: macOS with Xcode required; no Swift/ObjC compile performed.'
    exit 77
fi
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
src="$root/src/ios/Views/Settings/ApelinNative"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT HUP INT TERM
# Task/continuations require macOS 10.15+; use an explicit 12.0 floor
# for both compilers instead of inheriting a runner's deployment target.
mac_target="$(uname -m)-apple-macosx12.0"
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -target "$mac_target" -fobjc-arc -fblocks -isysroot "$sdk" -c "$src/MinisApelinHelloTransport.m" -o "$tmp/hello.o"
xcrun --sdk macosx swiftc -swift-version 5 -target "$mac_target" -sdk "$sdk" \
    -import-objc-header "$src/MinisApelinHelloTransport.h" \
    "$src/ApelinHelloInspection.swift" "$root/Validation/ApelinNative/main.swift" \
    "$tmp/hello.o" -framework Foundation -framework Combine -o "$tmp/check"
"$tmp/check"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$sdk" \
    -fobjc-arc -fblocks -fsyntax-only "$src/MinisApelinHelloTransport.m"
xcrun --sdk iphoneos swiftc -swift-version 5 -target arm64-apple-ios16.0 -sdk "$sdk" \
    -import-objc-header "$src/MinisApelinHelloTransport.h" \
    -typecheck "$src/ApelinHelloInspection.swift"
echo 'PASS: touched native bridge and Swift logic compiled with macOS/iOS SDK; full app/UI/device remains separate.'
