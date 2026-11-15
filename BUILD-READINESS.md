# Build readiness — 2026-11-15

No push, CI trigger, installation or successful Swift/full-app build is claimed.
Before edits: `../snapshots/build-readiness/before.tar.gz` (entire source tree).
Original baseline: `../minis.tar.gz`, SHA256 `04fcded42d0cfcbb72c14fc3f52d189e4ff90a80f8747cb594436df623da1878`.

## Locked sources

GitHub API `https://api.github.com/repos/qq6688000/OpenMinisBuild/git/trees/e5239f9f3ad4bc0d9810185b05673aaa13d88c47?recursive=1` returned `truncated: false`. Its mode-160000 entries and `.gitmodules` establish:

| Path | Repository | Exact commit | Download SHA256 |
|---|---|---|---|
| deps/ish | OpenMinis/ish-arm64 | 0fd17a135e78b7a0cf08a4f5831217bbb76ed22f | d26a47031c8ecf306e5c2c20989549be2383100c051c25cd0adab8d6e5c8e526 |
| deps/proot | OpenMinis/proot | 8b31a69345730692f2f49a88694fdcaec78b2031 | e8fb7d261bf1e9ff362f46b75136c32ae62ae4b5cb17f8cc7d2bfd11a487f7fe |

Download URLs are `https://codeload.github.com/{repository}/tar.gz/{exact-commit}`. Raw API responses and archives are retained outside the source tree in `../snapshots/build-readiness/`. Both destinations were empty before recovery. Archive member bytes and symlink targets verified: iSH 1852 regular files; PRoot 312. Extraction timestamp-setting errors on this host did not affect verified bytes. No existing nonempty edits were overwritten. Restored sources have no Git metadata.

For an archive checkout, run `python3 Validation/ApelinNative/restore-locked-deps.py` (Python 3.12+ recommended). It verifies download hashes, restores empty directories, and verifies rather than overwrites nonempty directories. Extra local files are retained. It does not claim to initialize recursive submodules.

The iSH tree API at `https://api.github.com/repos/OpenMinis/ish-arm64/git/trees/0fd17a135e78b7a0cf08a4f5831217bbb76ed22f?recursive=1` also returned `truncated: false`, identifying nested gitlinks:

- deps/libapps: ish-app/libapps @ b8cacae35e5b11d64bb736a053921c16ca7faf9e
- deps/libarchive: libarchive/libarchive @ fc6563f5130d8a7ee1fc27c0e55baef35119f26c
- deps/linux: ish-app/linux @ 8ec9bf17f89c6dba818f3ed2427de4223e78644a (upstream update=none)

These nested sources have NOT been recovered. `deps/build_ish.sh:init_submodules` invokes Git when libapps/.git is missing, so archive-only recovery is not a full replacement for a recursive Git checkout. For the eventual macOS build use a real checkout of the pinned parent and `git submodule update --init --recursive`, then apply the cumulative patch; GitHub's existing checkout already requests recursive submodules. For an archive-only build, nested sources and the Git initialization assumption must first be resolved explicitly. Do not silently skip this failure.

## Registration audit and actual compiler evidence

`ISHKernel.m` imports NativeBuildOffload.h and calls native_build_offload_register. All five NativeBuild C/ObjC implementation units remain registered in Xcode Sources. The restored native_offload.h defines native_handler_func as `(int, char **, int, int, int) -> int`, matching nb_handler; native_offload_add_handler returns int, matching the registration/error path. The locked implementation supplies pipe-backed stdout/stderr, compatible with the existing nonblocking FIFO output handling. No submodule patch was necessary.

Actual local command (exit 0; 27 pre-existing nullability warnings):

```sh
clang -target arm64-apple-ios16.0 -isysroot /opt/theos/sdks/iPhoneOS16.5.sdk \
  -fobjc-arc -fblocks -I deps/ish -I src/ios/NativeOffloads \
  -c src/ios/NativeOffloads/NativeBuildOffload.m -o /tmp/native-build.o
```

Adding -Werror fails on existing NativeOffloadUtils.h nullability annotations; no warning suppression or source workaround was introduced. This object compile is not a full link/runtime test.

`sh Validation/ApelinNative/check-objc-cross.sh /tmp/hello-check` passes the actual hello .m arm64 iOS compile with -Werror, strict SDK dylib link, public header syntax and private-XPC isolation checks. Python native source checks and model/template validation pass (121 provenance files and 16 generated projects). Neither check executes Swift.

## Swift and workflow readiness

Both existing workflows run `sh Validation/Apelin/run-swift.sh` and `sh Validation/ApelinNative/run-apple.sh` immediately after Xcode selection/version and before dependency installation/build. The subsequent CI preparation pins GitHub Xcode 26.2 and ports Codemagic's SwiftPM resolution, toolchain provisioning, signing and packaging bodies verbatim into the existing GitHub workflow. Native dependency build steps remain unchanged. Failures propagate; no continue-on-error added. The historical validation results below predate this CI alignment; CI-PUBLISH-PLAN.md describes the publication candidate.

Harness source inspection: model/adapter use Foundation and CryptoKit, no UIKit-only types; native inspection uses Foundation, Combine, Task and checked continuations. Explicit host-architecture macOS 12.0 targets and macOS SDK remove accidental old deployment-target defaults. Swift language mode 5 matches the app target overrides (the project-level 6.0 setting does not override those). The model harness retains real Bundle.main resource lookup and actual fixture/generation code. Native harness imports the actual public ObjC header with NS_SWIFT_NAME(probe(completion:)), compiles actual transport/state logic, exercises cancellation and decoder validation, then typechecks the state logic for iOS 16. No mocks were substituted. Source inspection cannot establish Swift importer/compiler success; both harnesses return 77 locally because swiftc/xcodebuild are absent. UI/whole-app compilation remains unrun.

## Full bridge prerequisites

`sh Validation/ApelinNative/check-full-bridge.sh` uses the exported roots from the app target and explicitly supplies iSH, NativeOffloads, Debug, Diagnostics and Shared source directories that Xcode header maps normally resolve. It requires actual `deps/include/ish/ish.h`, exported native_offload.h and Rclone's librclone.h. `deps/build_ish.sh` generates the umbrella header and copies real headers; `deps/build_rclone_ios.sh` generates the Rclone framework. No placeholder headers are created. Current exit 77 is expected: these outputs are missing. Restoring deps/ish cannot itself satisfy the umbrella include. On macOS after building native dependencies:

```sh
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)" CLANG="$(xcrun --find clang)" \
  sh Validation/ApelinNative/check-full-bridge.sh
```

The local SDK is iOS 16.5. The main app deployment target is iOS 16.0 (Widget 16.2); test targets use 26.2, and HealthKitOffload.m references the iOS 26.2 hypertension API. Deployment floor and build SDK are different requirements. Full readiness still requires a compatible Xcode/iOS SDK, real native libraries/frameworks, SwiftPM resolution, full unsigned device compilation and later device acceptance. Existing GitHub macos-15/Xcode selection must be checked for iOS 26.2 availability before relying on it. No successful IPA is reported.

## Cumulative delivery

`../deliverables/build-readiness/source.patch` and `apelind-hello-cumulative.tar.gz` are alternative cumulative application methods against ORIGINAL minis.tar.gz. Apply one only, from the extracted repository root:

```sh
git apply --check /path/to/source.patch
git apply /path/to/source.patch
# OR: tar -xzf /path/to/apelind-hello-cumulative.tar.gz
```

The packager prunes `deps/ish` and `deps/proot` as gitlinks before traversal. It filters newly generated objects/libraries, caches, exported native outputs and downloaded archives. All files present in ORIGINAL minis.tar.gz take precedence over artifact heuristics and are retained, including any baseline binaries/objects and template PNG assets; this is an archive-baseline comparison, not a claim that local Git metadata exists. The exact policy and baseline/source counts are in `scanner-policy.json`. No generated dependency sources are vendored into the cumulative overlay or patch.

FILES.sha256 records source payload hashes; ORIGINAL.sha256 identifies the baseline. Independent fresh patch and overlay reconstructions check both the entire filtered file set and bytes (plus symlink identity), and run both Python validators and actual hello ObjC checks. See `apply-verification.log`, `fresh-*-source.log`, `fresh-*-model.log` and `fresh-*-objc.log` for results. Recovery of pinned dependencies is a separate operation above. Previous deliverable directories and their snapshots remain preserved; the old packager is saved at `../snapshots/build-readiness/package-hello.before.py`, and the updated cumulative snapshot is `after-cumulative.tar.gz` in that directory.

Offline provenance verification rechecked the saved API gitlink entries, both archive SHA256 values, and all 1852 iSH / 312 PRoot regular-file bytes and archive symlink targets. No downloads or credentials were needed. PyYAML 6.0.2 parsed both workflow configs; comparing their step arrays against ORIGINAL minis.tar.gz confirms every original step/body remains unchanged, with exactly two harness steps immediately after Xcode. Python syntax and shell `sh -n` checks passed for both validation directories and the packager.

Executed readiness checks are recorded in `readiness-verification.log`. Full bridge validation returns 77 before compilation because `deps/include/ish/ish.h`, `deps/include/ish/kernel/native_offload.h`, and `deps/frameworks/Rclone.xcframework/ios-arm64/Headers/librclone.h` are absent. Both Swift harnesses also return 77 because this host lacks macOS/Xcode. These are blockers, not successful compile results. No remote CI, push or new product functionality is part of this delivery.
