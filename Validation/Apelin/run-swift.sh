#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ] || ! command -v xcrun >/dev/null 2>&1; then
    echo 'BLOCKED: macOS and Xcode Command Line Tools (Swift + CryptoKit) are required.' >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPO=$(CDPATH= cd -- "$ROOT/.." && pwd)
SRC="$REPO/src/ios/Views/Settings"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/minis-swift.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
APP="$WORK/Validation.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
cp -R "$SRC/ApelinTemplates" "$APP/Resources/ApelinTemplates"
# Bundle.main resource lookup is exercised unchanged, with real bundle layout.
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.minis.apelin.validation</string><key>CFBundleExecutable</key><string>validate</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
# CryptoKit requires macOS 10.15+; match the native harness's explicit floor.
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx swiftc --version
xcrun --sdk macosx swiftc -sdk "$SDK" -target "$(uname -m)-apple-macosx12.0" -swift-version 5 "$SRC"/ApelinModel/*.swift "$SRC/ApelinProjectAdapter.swift" "$ROOT/Apelin/main.swift" -o "$APP/MacOS/validate"
"$APP/MacOS/validate" "$ROOT/Apelin/Schemas/Fixtures"
