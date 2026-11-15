# Swift integration review — 2026-11-15

## XPC header compile fix

The missing iPhoneOS SDK xpc/xpc.h blocker is fixed with implementation-only MinisApelinXPCPrivate.h, a minimal subset sourced from pinned Apple SDK declarations. ARC object typing, exported type-object addresses and +1 create ownership are preserved. No protocol/authentication/entitlement changes. Snapshot: ../snapshots/apelind-xpc-compile/before.tar.gz.

`sh Validation/ApelinNative/check-objc-cross.sh ../deliverables/apelind-xpc-compile` passed actual arm64 iOS .m compilation with -Werror, strict SDK dylib linking and isolated public bridge compilation. Full-app bridge compilation stops at missing ish/ish.h. Swift tooling is absent; Swift/UI/whole-app builds and device behavior remain unverified. Provenance, exact evidence and reproducible commands: Validation/ApelinNative/XPC-ABI.md. Earlier statements below about unrun Apple validation still apply to Swift and runtime, but no longer imply ObjC cross compilation is unavailable.

## Native hello follow-up

Reviewed upstream AGENTS hard rules, wire/system-only/license/build sections, AppProtocol, XPCEnvelope, HelloResponse, DaemonClient and Proxy/PeerAuthenticator. The user explicitly excludes push/CI/install; no upstream files changed. Implemented only real XPC hello and UI snapshot inspection, preserving the previous project/model/template integration. Objective-C avoids the Swift XPC constant-overlay compatibility issue documented upstream. The minimal transport intentionally has no generic operation or descriptor execution surface.

Source review covers serial one-shot completion; generation rejection of late replies; clearing snapshots on lifecycle transitions; upstream 5-second attempt / 10-second first-miss grace semantics; request correlation, typed envelopes, incompatible-version errors, payload bound and unexpected fd rejection. A successful hello proves that exchange only; UI does not expose build-ready or installed-toolchain claims. Unknown operation names are preserved for inspection. Remote denied is distinct from transport unavailability; upstream authentication cancellation has no denial payload and remains explicitly ambiguous. No entitlement/path authentication was weakened or bypassed. No exact privileged Minis install path was found; a daemon peer patch is deliberately absent.

Apple-toolchain entry `Validation/ApelinNative/run-apple.sh` compiles the actual .m and Swift state/decoder, tests valid/invalid snapshots and cancellation-vs-timeout single completion on macOS, then typechecks actual touched native logic with iPhoneOS SDK. A fixed NS_SWIFT_NAME removes method-import naming ambiguity. This entry is provided but UNRUN: Linux invocation returns 77, no swiftc/xcodebuild. Full app/UI typecheck, real peer acceptance/rejection, service-absent startup, timeout/reply races on device and background/UI behavior remain acceptance tasks. No successful handshake is claimed on this host.

Static native source/provenance/registration check and prior 121-file provenance/16-generation/template/plist/binary/Linux recipe checks passed; upstream reference fixtures passed. Shell syntax of Apple entry passed. These checks are not compiler evidence. Before snapshot: `../snapshots/apelind-hello/before.tar.gz`; after snapshot and cumulative delivery checksums accompany this slice. Deliverables under `../deliverables/apelind-hello/` apply to original minis.tar.gz, retaining prior Settings navigation and binary template assets. Prior review below is historical where it says no transport was added.

Reviewed DevelopmentProjectsView.swift, ApelinProjectAdapter.swift, all eight ApelinModel sources, SettingsSheet.swift and Xcode source/resource registrations against IMPLEMENTATION.md.

Changes before review were snapshotted at ../snapshots/swift-review/before.tar.gz. The upstream model remains unchanged. No CI/provider files changed; no remote push.

## Findings and fixes

- Previous deliverable used an intermediate snapshot baseline and omitted SettingsSheet's original Development navigation change. Rebuilt cumulative source.patch and overlay from ORIGINAL ../minis.tar.gz, including SettingsSheet, all source registrations, actual templates and three binary PNG icons. source.patch is a git binary patch; overlay includes the same complete file contents.
- Adapter path checks previously covered input reads only. Extracted checkedURL and now check template directory and substituted output paths before writes; existing template outputs are rejected. Direct adapter calls now enforce the same project-name restriction as the UI. Staging ownership remains with the UI store; callers must provide a fresh staging directory. Checks remain best effort against concurrent filesystem mutation, not descriptor-based isolation.
- TemplateError had CustomStringConvertible but no LocalizedError: UI localizedDescription lost useful validation errors. Added adapter-local LocalizedError conformance without modifying upstream model provenance.
- Checked adapter signatures against imported APIs, model dependencies Foundation/CryptoKit, folder resource Bundle.main lookup, eight model Sources registrations, adapter/UI Sources registrations and Settings group paths. No definite API signature mismatch found by source review. This is not Swift compiler evidence.

## Standalone actual Swift validation

On macOS with Xcode Command Line Tools, from repository root:

```sh
sh Validation/Apelin/run-swift.sh
```

The script compiles the actual eight imported model files plus actual ApelinProjectAdapter.swift and main.swift, using Swift language mode 5 matching the app target. It makes a temporary macOS app bundle containing actual ApelinTemplates so the unchanged Bundle.main resource lookup is tested. No Minis app build, Swift package dependency download, UI stub or Python substitute is involved. Temporary files are cleaned on exit.

The Swift runner covers four native template descriptors/digests, 16 generations, project identity mismatch rejection, XML plist parse, binary copy equality, license preservation, unresolved placeholders, strict JSON rejection, unsafe paths, symlink descendants, oversized reads and imported project/extension valid/invalid fixtures. It does not typecheck SwiftUI, SettingsSheet or AIChatViewModel and does not test iOS signing/runtime.

## Evidence and blockers

Installed: Python 3, git, tar. Missing: swift, swiftc, xcodebuild. `sh -n Validation/Apelin/run-swift.sh` passed. Running the Swift entry on this Linux host reports BLOCKED and exits 77; Swift compilation and Swift test execution have NOT happened. Run it on macOS before claiming typecheck/test acceptance.

`python3 Validation/Apelin/validate.py` passed: 121 provenance hashes, four template digests, 16 reference-generated projects, plist/binary/negative checks, Linux C recipe success and compiler-failure propagation, and static Xcode registrations. `python3 Validation/Apelin/Schemas/Tools/check-fixtures.py` passed all upstream reference fixtures (requires /private/tmp here). These remain Python/reference evidence only.

Delivery reconstruction verification is recorded in ../deliverables/apelin-native-projects/apply-verification.log: fresh original extraction, git apply --check, patch apply, byte equality, independent overlay apply and byte equality. Original archive SHA-256 and payload SHA-256 are recorded with the delivery.

Remaining acceptance: run actual Swift harness on macOS; compile iOS target with its real dependencies; create all five project types on device; test refresh, duplicate names/IDs, malformed manifests, file preview bounds and app-group shared paths. UI I/O remains synchronous. No native build/install/signing capability was added or verified.
