# Development projects: Apelin native model and templates

## Read-only native hello slice (2026-11-15)

This section supersedes earlier statements that no transport exists. DevelopmentProjectsView now offers an explicit read-only Apelind inspection. ApelinNative/MinisApelinHelloTransport.m uses the real libSystem Mach XPC service `wiki.qaq.apelin.service`: dictionary `op=hello`, int64 protocolVersion=2, UUID requestID and data payload `{}`. This is not a JSON socket or shell protocol. Swift decodes the actual HelloResponse shape (installRoot, protocolVersion, operations). Only hello is callable; no build/install/environment mutation or fd forwarding API is exposed. The full upstream package graph remains unimported.

Replies require typed ok, matching requestID, bounded payload (256 KiB), compatible version and a meaningful hello operation list. Upstream's pre-decode unsupportedVersion error has an empty requestID and is handled explicitly. Explicit denied errors retain their code/message/reason; connection closure is honestly ambiguous (missing service, sandbox restriction or rejected peer). A 5-second per-attempt bound and 10-second grace measured from the first miss allow launchd startup; cancellation/reply/timeout completion is serialized once. Grace is checked after each completed attempt, so it can exceed 10 seconds by one attempt. The probe closes the connection after hello; UI labels it a timestamped snapshot, never a live/ready build backend. Backgrounding or leaving the screen cancels and clears it. Upstream advertises known operations whether implemented or not; names never enable actions.

No daemon/authentication/entitlement edits were made. Current upstream authenticates before decoding: uid 0/501, true wiki.qaq.apelin.client, no-sandbox and platform-application entitlements, canonical `<installRoot>/Applications/Apelin.app/Apelin`, root-owned executable without group/world write. Minis.native.entitlements includes two private flags but lacks wiki.qaq.apelin.client; normal Minis entitlement/signing does not establish admission. No source-backed privileged Minis package install path was established, so no guessed daemon peer patch is delivered. A separately reviewed packaging/signing identity and exact peer admission preserving every existing check is prerequisite to successful device hello. Bundle ID alone is insufficient.

Objective-C/Swift sources, header references, bridging import and MIT/provenance notice folder resource are registered in Xcode. Existing eight model files and all templates retain byte-identical provenance. Snapshot before edits: `../snapshots/apelind-hello/before.tar.gz`; added paths are listed by scope.json. New Apple validation: `sh Validation/ApelinNative/run-apple.sh` compiles actual ObjC and Swift on macOS, exercises actual payload decoding/one-shot cancellation, and typechecks both against iPhoneOS SDK. It does not compile DevelopmentProjectsView or prove privileged-device admission. Linux checks: `python3 Validation/ApelinNative/check-source.py ../Apelin-main`, existing validate.py and upstream reference fixture runner passed. Apple entry shell syntax passed; execution exited 77 because this host lacks macOS/Xcode/Swift. Actual ObjC arm64 iOS compilation and strict SDK link now pass via `Validation/ApelinNative/check-objc-cross.sh`; see `Validation/ApelinNative/XPC-ABI.md`. Swift compilation and device runtime tests remain unrun.

Cumulative delivery is rebuilt against original `../minis.tar.gz`, including prior source/UI/template changes and binary PNG resources; independent fresh-baseline patch and overlay applications must match payload bytes. No push, CI change, install or destructive build command was run.

Review update: see REVIEW.md. macOS standalone actual-model/adapter validation is now `sh Validation/Apelin/run-swift.sh`; this host lacks Swift, so it has not compiled or run here. Delivery now uses the ORIGINAL minis.tar.gz baseline and includes the initial SettingsSheet navigation change and binary templates. Adapter output paths/name validation and localized errors were hardened; upstream model/resource bytes remain unchanged.

## Current implementation (2026-11-15)

This section supersedes the initial integration notes below, including their statements that no Apelin code was copied and ObjC creation was deferred. Native project creation is now available independently of build capability.

- The picker offers the existing Linux C CLI and four genuine upstream Objective-C templates: UIKit App (`app` 0.1.1 / `uikit-objc`), CLI (`cli` 0.1.2 / `objc`), Tweak (`tweak` 0.1.1 / `objc-hook`), Preferences (`preferences` 0.1.3 / `objc-bundle`).
- `ApelinModel/` contains eight byte-identical upstream ApelinProject files: JSONDocument, CanonicalJSON, SchemaValidator, EmbeddedSchemas, ProjectDocument, ProjectValidation, ExtensionManifest and Templates. These reuse strict JSON parsing, schema and semantic validation, typed model decoding, parameter typing/context validation, format-aware escaping and canonical template digest calculation. They compile directly into the Minis target with Foundation/CryptoKit. The full ApelinKit SwiftPM graph, Core/Protocol, daemon and workers are not imported; inspecting these showed native transport/filesystem/process and package dependency closures unnecessary for creation.
- `ApelinProjectAdapter.swift` supplies the bounded no-symlink `ProjectFiles.read` operation required by TemplateDigest, validates extension manifests and template digests, substitutes using upstream functions, parses generated XML plists, validates generated Apelin manifests, and preserves provenance/license files in each created project.
- `ApelinTemplates/` is a folder resource registered in the app Resources phase; every model and adapter Swift file is registered in app Sources. Four complete development extension directories retain manifests, all declared templates, support headers/stubs, binary icons and original MIT notices. Only the four ObjC templates are exposed. Additional upstream Swift/C assets remain to keep complete extension manifests and their provenance intact.
- Existing `minis-project.json` v1 remains the Minis catalog record. Native records use `apelin-app`, `apelin-cli`, `apelin-tweak`, or `apelin-preferences`, target `ios`, buildRecipe `unconfigured`; an actual separate `apelin-project.json` carries upstream schema v1. UUIDs agree. Loading validates that manifest and checks the pinned template identity. Linux manifests and recipes remain compatible.
- Original name restrictions, shared/projects location, staging/rename creation and 256 KB regular-file preview limit remain. Native previews follow the upstream file list (binary icons are copied, not decoded as text), plus README and attribution. Product names convert hyphens to underscores; bundle/package IDs use `com.example.` plus lowercase name with underscores converted to hyphens. Other parameters use upstream defaults, with project display name and clearly Minis-specific author/summary. Tweak's default target is SpringBoard.

## Native capability boundary

Native templates target jailbroken iOS 16+ rootless/roothide. No build/install/signing action is exposed or claimed. Both environment bindings use explicit sentinel IDs (`minis-unbound-toolchain`, `minis-unbound-sdk`) and zero SHA-256 digests; these satisfy the document shape but are NOT real registered environments. A future backend must resolve and replace both IDs/digests from a verified registry. This differs from full Apelin creation, which binds real installed environments. App templates include elevated entitlements ordinary signing cannot grant. Tweak/preferences require their matching extension support and runtime dependencies; the support assets remain with their original bundled extensions, not masquerading as installed SDK components. No NativeBuildOffload probing, transport, compilation or installation was added.

## Provenance and reproducible validation

Source archive: `/var/minis/workspace/fusion/Apelin-main`, repository `https://github.com/owngoal-dev/Apelin`. This archive has no .git metadata: its upstream commit is unknown. Exact provenance is the 121 per-file SHA-256 records in `src/ios/Views/Settings/ApelinTemplates/PROVENANCE.json`, extension versions/template digests, and unchanged nested origin commits/paths in each extension manifest. Original MIT copyright notices (including OwnGoal Studio) accompany model, resources, validation sources and generated projects. No upstream files were edited.

Existing files were snapshotted BEFORE editing under `/var/minis/workspace/fusion/snapshots/apelin-native-projects/`: DevelopmentProjectsView.swift, project.pbxproj and this document. Other changes add new files. No remote push.

Run from repository root:

```sh
python3 Validation/Apelin/validate.py
# The unchanged upstream fixture runner assumes this Darwin-style temporary directory exists:
mkdir -p /private/tmp
python3 Validation/Apelin/Schemas/Tools/check-fixtures.py
```

Results: all 121 hashes match; all bundled extension manifests/template digests validate; 16 native project generations (four templates × four representative valid names) pass reference schema/semantic rules, plist parsing, binary-copy equality and unresolved-token checks. Duplicate products, invalid digests, duplicate JSON keys, floating-point JSON and BOM inputs are rejected. Format escaping checked. Existing Linux literal recipe builds/runs `Hello from Minis!`; invalid C exits nonzero. All upstream reference fixtures pass, including canonical JSON, placeholder contexts, escaping, manifest formatting and build/packaging digest mutations. Xcode source/folder-resource references are present.

These tests execute the unchanged upstream Python reference implementation and Linux recipe, NOT the Swift adapter. This Linux environment has no Swift compiler, Xcode, simulator or device build: Swift type checking and UI/runtime behavior remain unverified. Required acceptance on Xcode/device: build app, create all five types, inspect copied PNGs/plists/notices, reopen and refresh, mutate native manifest to test warnings, reject duplicate names/symlinks/oversized files, and confirm no build/install controls appear. UI I/O is synchronous and path checks are best effort rather than descriptor-based race-proof isolation. General import/migration, parameter-editing UI, editing/rename/delete, environment binding and native backend remain separate work.

## Initial integration record (historical)


## Changes

- `src/ios/Views/Settings/SettingsSheet.swift`: adds a Development section with a native navigation link to 开发项目.
- `src/ios/Views/Settings/DevelopmentProjectsView.swift`: new self-contained SwiftUI project catalog, creation form, detail screen, read-only source/manifest previews and filesystem store.
- `src/ios/Minis.xcodeproj/project.pbxproj`: registers the new file in PBXBuildFile, PBXFileReference, the Settings group and the app Sources phase.
- No CI, providers, native offload implementation or existing feature behavior changed. No push was performed. This checkout has no .git metadata, so review used snapshot diffs.

## Storage and behavior

Projects live in `AIChatViewModel.minisAppGroupRoot/shared/projects`, exposed to the Linux shell as `/var/minis/shared/projects`. The trusted app-group root is canonicalized first to allow iOS system path aliases. Descendant symbolic links are rejected. Names must match `\A[a-zA-Z][a-zA-Z0-9_-]{0,47}\z`. Existing names are never overwritten.

Creation writes a hidden, unique staging directory and moves it into place only after all files are written; staging is cleaned up on normal failure. Interrupted hidden staging directories are not listed. Files generated:

- `minis-project.json`: schemaVersion 1, UUID id, name, template `c-cli`, target `linux`, createdAt (Foundation JSON date: seconds since 2001-01-01 UTC), buildRecipe `sh build.sh`.
- `Sources/main.c`: original minimal C hello program.
- `build.sh`: original POSIX shell recipe using `${CC:-cc}`, C11, warnings-as-errors, output `build/hello`; nonzero compiler errors propagate.
- `README.md`: target, requirements, manual build/run commands, editing and backend limitations.

The catalog reloads on appearance, foregrounding and pull-to-refresh. Invalid manifests, duplicate IDs and unsupported project directories are reported separately rather than silently imported. Preview is limited to four known regular UTF-8 files, each at most 256 KB. This is initial create/list/browse management; editing is through the shared folder or terminal. Rename, delete and import are not offered.

## Honest backend and template scope

The project UI explicitly says its build backend is unconfigured. It has no build/install button and does not claim builds, signing or installation occurred. This refers to the new project UI integration, not a global claim that the repository lacks native build infrastructure. Existing NativeBuildOffload.m includes doctor/provision/run primitives; this slice does not connect or probe them. Runtime availability and end-to-end iOS compilation/signing are not verified here.

Only a Linux C CLI template is offered. On Alpine the user can install compiler prerequisites with `apk add build-base`, then run:

```sh
cd /var/minis/shared/projects/<project-name>
sh build.sh
./build/hello
```

This produces a Linux executable, not an iOS product. ObjC app/tweak templates are deferred until SDK, toolchain, signing and relevant runtime support are verified. The Apelin UIKit template requires Foundation/UIKit and app bundling/signing; its tweak additionally requires substrate and packaging/filter support.

## Reference and licensing

Read the Apelin AGENTS.md guidance relevant to projects/templates and reviewed `Extensions/Development/wiki.qaq.apelin.dev.cli/templates/c/{apelin-project.json,Sources/main.c}`, plus the UIKit ObjC and ObjC tweak manifests. The inspiration is validated on-disk project manifests and source templates. No Apelin source/template content was copied; the manifest format and minimal C/shell files are original. No Apelin license text needs to be embedded for these original files. No files in Apelin were modified.

## Snapshot and validation

Before changing existing files, copied SettingsSheet.swift and Minis.xcodeproj/project.pbxproj, preserving their relative paths, under `/var/minis/workspace/fusion/snapshots/development-projects-initial/`.

Performed:

1. Extracted the exact C and shell string literals from DevelopmentProjectsView.swift into a temporary directory, ran `sh build.sh`, and executed the result: output was `Hello from Minis!`.
2. Replaced that temporary C input with invalid syntax and verified the same recipe exits nonzero. Temporary files were removed.
3. Reviewed unified diffs against both snapshots: one settings section and four Xcode registration additions only.
4. Checked new Xcode build/file ID occurrence counts (2 and 3 respectively).

No Swift compiler, Xcode, simulator or device build was available. Swift type checking, Xcode project parsing and UI runtime behavior remain unverified; C recipe validation is not evidence of successful iOS compilation.

## Remaining work / device acceptance

- Build the iOS target with Xcode and check Settings → Development → 开发项目.
- Create a valid project, reopen the app and verify persistence; verify duplicate and invalid names fail without altering existing files.
- Verify shared-folder visibility, all four previews, refresh after external edits, malformed/unsupported manifests, symlink rejection, and oversized preview errors on device.
- The store uses bounded per-file synchronous I/O on the UI thread; large catalogs need background loading/pagination. Path validation is best effort against external edits, not race-proof openat-style filesystem isolation.
- Add a capability-driven backend adapter before enabling automated builds; surface measured compiler/SDK/signing availability, run logs and real artifact checks.
- Add ObjC templates only after a device end-to-end build recipe succeeds; integrate install only with real supported backend results.
- Add localization resources and broader project editing/import/rename/delete features in separate reviewed slices.
