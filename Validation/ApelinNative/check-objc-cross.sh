#!/bin/sh
# Linux clang/LLVM + an iPhoneOS SDK; no device execution or Swift claim.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
src="$root/src/ios/Views/Settings/ApelinNative"
sdk=${SDKROOT:-/opt/theos/sdks/iPhoneOS16.5.sdk}
cc=${CLANG:-clang}
ld=${LD64:-ld64.lld}
out=${1:-$(mktemp -d)}
mkdir -p "$out"
"$cc" --version
"$ld" --version
# Compile the actual implementation (not a mock or syntax-only replacement).
"$cc" -target arm64-apple-ios16.0 -isysroot "$sdk" -fobjc-arc -fblocks -Werror \
    -c "$src/MinisApelinHelloTransport.m" -o "$out/hello.o"
# Strict link against SDK stubs: unresolved symbols are fatal by default.
"$ld" -dylib -arch arm64 -platform_version ios 16.0 16.5 \
    -syslibroot "$sdk" -lSystem -lobjc -framework Foundation \
    -install_name @rpath/MinisApelinHelloProbe.dylib \
    "$out/hello.o" -o "$out/hello.dylib"
# Compile the Foundation-only public bridge in isolation and check that it
# does not expose the private XPC typedefs to Swift's Clang importer.
"$cc" -target arm64-apple-ios16.0 -isysroot "$sdk" -fobjc-arc -fblocks -Werror \
    -x objective-c-header -fsyntax-only "$src/MinisApelinHelloTransport.h"
"$cc" -target arm64-apple-ios16.0 -isysroot "$sdk" -fobjc-arc -fblocks \
    -x objective-c-header -E "$src/MinisApelinHelloTransport.h" > "$out/public-bridge.i"
if rg -q 'MinisApelinXPCPrivate|typedef.*xpc_object_t' "$out/public-bridge.i"; then
    echo 'FAIL: private XPC declarations leaked through public bridge'; exit 1
fi
llvm-objdump --macho --private-header "$out/hello.dylib"
llvm-objdump --macho --dylibs-used "$out/hello.dylib"
llvm-nm -u "$out/hello.o"
echo 'PASS: actual arm64 iOS ObjC object, strict SDK link, isolated public bridge.'
echo 'UNVERIFIED: Swift importer/typecheck, full app bridge/build, device XPC/authentication/runtime.'
