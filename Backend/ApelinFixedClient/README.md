# Fixed Minis client + Apelin companion backend

Status: NON-DEPLOYABLE PROTOTYPE. Fixed-client is the sole candidate route;
ApelinCompanion is an offline, unwired policy experiment. The current patch
preserves upstream authentication but DOES NOT yet enforce a final signed CDHash.
Both package entry points deliberately reject all packaging requests. No deb,
Files payload, installed service, or package-ready claim is part of this slice.
The current TrollStore/container Minis is not an accepted peer. Merely adding an
entitlement does not satisfy the fixed canonical executable path and ownership.

Security blockers: no final signed app was supplied, no trusted signing identity
verifier is available, and SDK exports do not document csops identity blob layout.
A caller-provided CDHash or matching bytes in a daemon is not signature proof.
The next patch must preserve every upstream check AND require a verified final
signed client hash, audit-token-bound observations, and the existing entitlements.
The fixed root-owned executable and all writable ancestor directories need device
review. Do not implement identity extraction from assumed numeric operations.
The existing patch remains reviewable source only until these gates are met.

## Identity and trust

`fixed-client.patch` changes only Apelind/PeerAuthenticator.swift. All original
checks remain: audit token PID and euid 0/501, wiki.qaq.apelin.client,
com.apple.private.security.no-sandbox, platform-application, canonical process
path, root-owned regular executable, owner execute bit, no group/world writes.
The original Apelin client remains accepted. The additional exact client is
`<hello install root>/Applications/Minis.app/Minis`, with the additional boolean
`com.openminis.apelin.client`. There is no wildcard, container-path allowance,
proxy open to other clients, CDHash replacement or entitlement-only bypass.
The package identity is `com.openminis.app`, executable `Minis`.
This grants the trusted client the SAME daemon authority as Apelin; the new UI
uses only read operations, but this patch is not a daemon read-only role.

## Prepare and build (manual, never run against the live install)

1. Review `upstream-inputs.json`. `prepare.py UPSTREAM NEW.patch` verifies these
   pins and generates the patch without modifying upstream. Apply the checked-in
   patch to a separate clean upstream copy using `git apply --check` then
   `git apply`. Preserve LICENSE, resources, workers, SDK/runtime dependencies,
   packaging scripts, and upstream checklist/build validation.
2. Build and package that Apelin tree with its own documented build and packaging
   process for the chosen rootless/roothide bootstrap. This companion is a patched
   full Apelin distribution, not a stripped standalone daemon. Its service name,
   install layout, workers and session-host behavior remain upstream's. Do not
   install both a stock and patched provider of wiki.qaq.apelin.service. Upgrading
   the existing Apelin package is an explicit later deployment decision.
3. Build the full Minis app retaining its frameworks, extensions, iSH, provider
   configuration and resources. Merge the four boolean entitlements above and
   the `wiki.qaq.apelin.service` entry in
   `com.apple.security.exception.mach-lookup.global-name` into the normal release
   signing inputs. Preserve all existing entitlement keys and sign nested code
   correctly. Do not add no-container as a shortcut. Package only the final signed
   bundle; package-client.py reads entitlements back using ldid, not a sidecar.
4. Packaging remains disabled. Future required order: sign all nested code and
   final main executable; verify trusted identity and all required entitlement
   values from that signed executable; obtain and pin the final running slice's
   CDHash; build/sign the patched daemon; package without changing signed bytes;
   extract and compare signed files, root ownership and modes. Any resigning must
   invalidate the daemon pin and restart this sequence. `ldid -e` only extracts
   entitlements and cannot establish signature validity or trust. This host's
   dpkg-deb DOES support `--root-owner-group` (confirmed using `--help`); the
   previous blocker was verification, not that option. No Files payload is
   provided because no deployable package can currently be produced.
5. Before any installation, audit the bootstrap's Applications ancestors: root
   ownership and no mobile-writable replacement directories, canonical install
   root from the daemon itself. On-device acceptance must prove both positive and
   negative peers before enabling build/install integration. LaunchDaemon must
   retain upstream on-demand behavior; no RunAtLoad or KeepAlive additions.

## Migration is required, not automatic

The fixed-path client uses the same bundle ID as the existing TrollStore app.
Registering both can conflict; never silently overwrite or double-register it.
Back up/export the original container, preferences, chats, model configuration,
rootfs, workspaces, attachments, mounts/bookmarks and any app-group data first.
Keychain access groups, security-scoped bookmarks, widget/FileProvider groups,
notification identity and sandbox/container assignment need device-specific
validation. A fixed package can receive a different home/container. Copying the
bundle or adding entitlements does not migrate data or preserve those identities.
Choose and review a data migration/rollback plan before registration; this slice
intentionally ships no data-copy or app-removal hook. Keep the original installed
app and its data untouched until that plan is accepted.

## Implemented operations and NativeBuild reuse

The existing bounded transport now sends only hello, sdkList with
includeSources=false/readSources=false, and toolchainStatus with an empty object.
No catalog/network request, setup, removal, compiler execution, shell, build,
artifact descriptor or install operation is exposed. The serial queue, correlation,
version error handling, 256 KiB cap, descriptor rejection, timeout and cancellation
are retained. SDK and toolchain responses are typed Swift read-only projections
of the pinned upstream definitions, with independent UI success/error state.
Empty registries are not errors; registered records and historical component
self-checks do not prove a compiler works now or that a project is build-ready.

Existing NativeBuildToolchain NBToolchainDescribe and minis-native-build doctor
already supply read-only local stat/access diagnostics; NBPRun and Mach-O
inspection can support a future local build lane. They describe a different,
app-staged toolchain, not Apelin's registered environment. Do not merge their
readiness booleans or use the generic NativeBuild run request as an authenticated
Apelin API. This patch preserves that infrastructure without changing execution
policy. Next build binding needs project import/descriptor ownership, typed
build requests/events/cancellation, artifact verification and explicit install
approval/Irisin compatibility; none is claimed here.

## Validation boundaries

Run `Validation/ApelinNative/check-objc-cross.sh` for actual iOS arm64 Objective-C
compile/link, `Validation/ApelinNative/check-source.py` for source invariants,
`Backend/ApelinFixedClient/test-policy.py UPSTREAM` for patch invariants and policy
model cases. The policy test is Python and does not generate or run Swift.
The companion test separately compiles and executes the pure C policy on host.
Run `Validation/ApelinNative/run-apple.sh` for actual Swift decoder/bridge checks.
Python source checks are not Swift compilation or device authentication evidence.
A full app build, patched daemon compilation, real audit-token/entitlement tests,
rootless/roothide registration, data migration and on-device hello/list/build/
install are still acceptance prerequisites. No remote push, CI run or service
installation is part of this delivery.
