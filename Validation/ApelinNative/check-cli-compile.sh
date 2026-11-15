#!/bin/sh
# Actual adapter implementation + strict SDK link, independent of iSH headers.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
sdk=${SDKROOT:-/opt/theos/sdks/iPhoneOS16.5.sdk}
cc=${CLANG:-clang}
ld=${LD64:-ld64.lld}
out=${1:-$(mktemp -d)}
mkdir -p "$out"
src="$root/src/ios/NativeOffloads"
cat > "$out/adapter.m" <<'EOF'
#import "NativeBuildOffload.h"
#import "NativeBuildProcess.h"
#import "NativeBuildToolchain.h"
#include <errno.h>
#include <string.h>
#include "NativeCLICompile.inc"
EOF
"$cc" -target arm64-apple-ios16.0 -isysroot "$sdk" -fobjc-arc -fblocks -Werror -I "$src" -c "$out/adapter.m" -o "$out/adapter.o"
"$cc" -target arm64-apple-ios16.0 -isysroot "$sdk" -fobjc-arc -fblocks -Werror -I "$src" -c "$src/NativeBuildToolchain.m" -o "$out/toolchain.o"
"$cc" -target arm64-apple-ios16.0 -isysroot "$sdk" -Werror -I "$src" -c "$src/NativeBuildProcess.c" -o "$out/process.o"
"$cc" -target arm64-apple-ios16.0 -isysroot "$sdk" -Werror -I "$src" -c "$src/NativeBuildMachOCore.c" -o "$out/macho.o"
"$ld" -dylib -arch arm64 -platform_version ios 16.0 16.5 -syslibroot "$sdk" -lSystem -lobjc -framework Foundation -install_name @rpath/NativeCLICompile.dylib "$out/adapter.o" "$out/toolchain.o" "$out/process.o" "$out/macho.o" -o "$out/adapter.dylib"
# Also compile the actual ObjC template with the exact fixed defines used by UI.
python3 - "$root" "$out" <<'PY'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:])
source=(root/'src/ios/Views/Settings/ApelinTemplates/wiki.qaq.apelin.dev.cli/templates/objc/Sources/main.m').read_text()
(out/'main.m').write_text(source.replace('{{productName}}','hello_cli'))
PY
"$cc" -target arm64-apple-ios16.0 -isysroot "$sdk" -x objective-c -fobjc-arc -O0 -g -DDEBUG=1 '-DAPELIN_VERSION="0.0.1"' '-DAPELIN_BUILD_ID="minis-native-compile"' -c "$out/main.m" -o "$out/main.o"
llvm-objdump --macho --private-header "$out/main.o"
echo 'PASS: actual native compile adapter, NBPRun and Mach-O inspector compile + strict iOS SDK link; actual ObjC CLI source compiles to arm64 object.'
echo 'UNVERIFIED: Swift/full app and device execution. No signing/install performed.'
