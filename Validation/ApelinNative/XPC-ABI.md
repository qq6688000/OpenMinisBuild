# XPC ABI and local compile evidence — 2026-11-15

The original arm64-apple-ios16.0 compile with iPhoneOS16.5.sdk, ARC, blocks and -Werror failed at `<xpc/xpc.h>` (header absent). Snapshot: `../snapshots/apelind-xpc-compile/before.tar.gz`; original diagnostic: `before.log` beside it. No daemon, authentication, entitlements or wire behavior changed.

`MinisApelinXPCPrivate.h` is an implementation-only subset. When the SDK provides xpc/xpc.h it uses that header; otherwise it declares only the 15 functions and four opaque type constants needed here. The separate Mach-service declaration also has the required retained-result annotation. The shim does not implement XPC or load a replacement library.

## Declaration provenance

Apple SDK headers mirrored by https://github.com/phracker/MacOSX-SDKs at immutable commit `041600eda65c6a668f66cb7d56b7d1da3e8bcc93`, directory `MacOSX11.3.sdk/usr/include/xpc/`:

- `xpc.h`: SHA-256 `df87cee978fef51f0bf02d24e760c270be0899ae5b61fd0ba0d3e414f5047bc8`
- `connection.h`: SHA-256 `1c458cd9be22377a1ac54232304fa07f1558df2762ca2ed207aacf7c86317c73`

Downloaded and verified at the pinned URLs. Reference files are retained outside the app at `../xpc-abi-reference/`; no wholesale SDK header redistribution is added to the source payload. These are Apple SDK declarations, not covered by Apelin's MIT license.

Source anchors: xpc.h lines 43–86 (`const struct _xpc_type_s *`, `OS_OBJECT_DECL(xpc_object)`, connection alias under ObjC, `XPC_RETURNS_RETAINED`); 101 (block callback); 159/274/285/303 (addresses of exported type objects); 409/573/1245 (type, bool, array accessors); 1914 (dictionary create, +1); 2008/2122/2213/2236/2443/2466 (borrowed dictionary accessors and setters). connection.h lines 190/317/343/520/588 provide create, handler, activate, send-with-reply and cancel. Activation is available since iOS 10; other used calls are annotated iOS 5 in this reference.

The shim preserves ARC object typing and both create functions' `OS_OBJECT_RETURNS_RETAINED`; borrowed getters remain +0. It does not guess struct layouts, tag values or substitute BOOL for C bool. SDK os/object.h supplies the actual ObjC macro. Optional nullability and diagnostic annotations are not duplicated; this private header is never a Swift interface.

Existing Apelin `Apelin/DaemonClient.swift` imports XPC and declares create_mach_service using @_silgen_name; its SHA is already recorded in Notices/PROVENANCE.json. That supports the chosen service API, but does not supply the missing C types. The inspected Minis source tree contained no reusable XPC header. The iPhoneOS16.5 SDK lacks these headers yet its `usr/lib/libSystem.B.tbd` exports all used XPC functions/type objects. Header absence does not imply absent runtime symbols or permission to contact the service.

## Reproduce

From the repository root:

```sh
SDKROOT=/opt/theos/sdks/iPhoneOS16.5.sdk \
  sh Validation/ApelinNative/check-objc-cross.sh ../deliverables/apelind-xpc-compile
```

CLANG and LD64 may override clang and ld64.lld. Requires LLVM tools and ripgrep. The script builds the actual .m object with `-target arm64-apple-ios16.0 -fobjc-arc -fblocks -Werror`, then strictly links against Foundation, libobjc and libSystem SDK stubs. No undefined-symbol suppression, dynamic_lookup, fake symbols or mock transport is used. It also syntax-checks and preprocesses the isolated Foundation-only public header to check for private-type leakage.

Observed with Alpine clang 19.1.4 / LLD 19.1.4: object compile PASS; strict dylib link PASS; public header compile/isolation PASS. Mach-O output is ARM64 DYLIB with NOUNDEFS/TWOLEVEL; SDK dylib dependencies include libSystem, libobjc, Foundation and CoreFoundation. Artifacts and full commands' output are outside the source tree in `../deliverables/apelind-xpc-compile/{hello.o,hello.dylib,check.log}`. A link against stubs proves symbol resolution, not device execution.

## Whole-app / Swift implications

The app target already includes the actual .m and ApelinHelloInspection.swift in Sources; ARC is enabled. The quoted include finds the new header relative to the .m without extra Xcode header paths or link flags. The app bridging header imports only MinisApelinHelloTransport.h, exposing NSData/NSError and NS_SWIFT_NAME(probe(completion:)); private XPC types remain outside it. ApelinHelloInspection.swift imports Foundation and Combine, not XPC. No Swift or public API edits were required.

A separate attempt to compile the complete MinisApp-Bridging-Header.h with the target's header-search paths stopped at missing `ish/ish.h` (line 17); log: `../deliverables/apelind-xpc-compile/full-bridge.log`. Existing iSH/FFmpeg/rclone build dependencies are not supplied by this fix. No full-app bridge success is claimed.

swiftc/xcodebuild are unavailable here. `run-apple.sh` exits 77 on this host; its macOS Swift decode/lifecycle harness and iOS Swift typecheck remain unrun. Device service admission, authentication, sandbox behavior and timeout/reply races remain unverified. Successful compilation/linking does not establish a successful hello or privileged peer admission.
