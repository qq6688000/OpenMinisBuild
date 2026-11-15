# REPORT — WorkBuddy account-switch model fix + 开发项目 removal

Branch `apelin-integration`, commit **4f8d721** (parent `98b3165`), local only — **not pushed, no CI triggered**.

Snapshot taken before any edit: `fusion/snapshots/wb-account-and-remove-projects/pre-edit/`

```
HEAD.txt, git-status.txt, dirty-tree.patch          ← exact pre-edit tree state
ProviderConfigStore.swift, QuotaStore.swift,
ProviderInstanceDetailView.swift, SettingsSheet.swift,
MinisApp-Bridging-Header.h, NativeBuildOffload.{h,m},
project.pbxproj, codemagic.yaml, DevelopmentProjectsView.swift,
ApelinProjectAdapter.swift, ApelinModel/, ApelinNative/,
ApelinTemplates/, Validation/Apelin/, Validation/ApelinNative/,
nbp_spawn_probe.c
```

Pre-existing dirty tree (uncommitted work that was **not mine**) was committed with mine so the branch
stays consistent: `NativeBuildProcess.c` (+169), `NativeBuildProcess.h` (+45), `NativeBuildProvision.m` (+37),
untracked `tests/nbp_spawn_probe.c`. It is part of the same native-spawn probe work as HEAD and builds
independently of both tasks.

---

## TASK 1 — WorkBuddy account switch kept the old account's models

### What was actually wrong

`refreshModels(for:)` is **additive by construction**, which is correct for a refresh and wrong for an
account switch. Three behaviours compound:

1. `replaceEntries` keeps `isCustom` entries the vendor no longer lists — so a model the *old* user added
   by hand survives any refresh.
2. `[T-model-absence-grace]`: catalog entries the vendor does **not** list this time are kept for
   **7 days** (`modelAbsenceGracePeriod`) — so the old account's catalog survives even a successful fetch.
3. On a fetch error `refreshModels` returns `.kept` — "Nothing was replaced" — so the old list survives
   **entirely**.

And the two switch points did nothing to compensate: the sign-in sheet only called `refreshModels`
on success, sign-out only cleared the Keychain token (`WorkBuddyOAuthManager.logout`) and toggled UI.

Third, non-model state that is keyed by the same `providerInstanceId` and therefore outlives the
credential: `ProviderCredentialCache` (L2 "has any credential") and `QuotaStore`'s
`instanceSubjects` / pools / `instanceNotes` (account usage shown under the same id).

### The fix (code)

`src/ios/Providers/ProviderConfigStore.swift`

```swift
@discardableResult
func removeAllModelEntries(for instanceId: String, reason: String = "account-switch") -> Int
```

* deletes **every** entry with `providerInstanceId == instanceId` (custom, unlisted, catalog — all of them);
* removes those ids from every `ModelGroup.memberEntryIds`, writing `removedMembers[e] = now` /
  `addedMembers[e] = nil` so a peer's union-merge cannot resurrect them (same stamps `updateGroup` writes);
* removes them from `agentLoopModelEntryIds`;
* tombstones them in `deletedModelEntries` (so the deletion travels through sync as positive data);
* `save()` (mirrors JSON + V3 SQLite, bumps `configRevision`, publishes to every observer);
* drops the caches keyed by that instance: `ProviderCredentialCache.shared.invalidate(instanceId)` and
  `QuotaStore.shared.forgetInstance(instanceId)` — deliberately **unconditional**, so a second purge whose
  entries are already gone still drops a cache the detached refresh may have re-filled.

It does **not** delete the instance, does not touch credentials, and never filters on any other id.
Nothing else in the store was changed semantically.

`src/ios/Providers/Quota/QuotaStore.swift`

```swift
func forgetInstance(_ instanceId: String)
```

Detaches `instanceSubjects[instanceId]` from its subject (dropping subject + pools + bindings + summaries
when the instance was the last user), also drops the instance-keyed **subscription** subject
(`accountKey == "instance:<id>"`, which is *not* keyed by the key hash and would otherwise survive), and
clears the "no credential" note. Result: the quota section goes back to `.loading` ("we do not know yet")
instead of showing the previous account's remaining usage. `lastViewed` is kept on purpose — the
credential-change hook uses it to re-resolve the instance against the new key.

`src/ios/Views/Providers/ProviderInstanceDetailView.swift`

* WorkBuddy sign-in (`WorkBuddyLoginSheet … { success in }`), inside `if success`:

  ```swift
  store.removeAllModelEntries(for: instance.id, reason: "workBuddy-sign-in")
  Task { await store.refreshModels(for: instance, caller: "workBuddy-sign-in") }
  ```

  Purge **before** the fetch, so the list the refresh starts from is empty.
* WorkBuddy sign-out (`oauthLogout`, `case .workBuddy`): token logout first, then
  `store.removeAllModelEntries(for: instance.id, reason: "workBuddy-sign-out")`.
  A signed-out provider therefore shows no models.

**Scoped to WorkBuddy**, as requested. Anthropic, Gemini, Codex, xAI, OpenRouter, Antigravity, Kimi,
Copilot, Trae and Raccoon sign-in/sign-out paths were verified unchanged (assertions [4] and [5] below).

Memory/storage: the pickers re-filter `config.modelEntries` per instance inside view bodies
(`shadowVoiceProviders`, `hasVoiceModels`, the Providers rows). After a purge deletes hundreds of rows that
is a re-scan per observer. Added one shared, single-slot per-instance slice cache
(`ModelEntriesByInstanceCache`, invalidated by the `@Published config` observer) so a purge costs one pass.
File-scope but **file-private**, no persistent storage, no behaviour change.

### UI refresh / authRevision

No new mutation path was invented. `authRevision` is already bumped by every credential write/delete
(`ProviderKeychainHelper.notifyAuthChanged`) — WorkBuddy login and logout both go through it — and both
consumers re-read on it: `QuotaStore`'s `$authRevision.dropFirst()` hook and
`ProviderRowCredentialCache.value(for:revision: store.authRevision)`. The purge publishes the new entry list
itself via `save()`, and the sign-out button also toggles `oauthRefreshTrigger`. I did **not** add a direct
`store.authRevision &+= 1` (it is `@Published`, so any future reader gets `@Published` semantics rather than
`objectWillChange`), and the comment says so.

### What is genuinely NOT explained by the fetch (honest limit)

WorkBuddy has **no** `/models` discovery endpoint: `fetchModelsForInstance` returns the compiled-in
`WorkBuddyModelsAPI.allModels` (15 hard-coded ids) with `ProviderType.oauthSupportsModelDiscovery(.workBuddy) == false`.
That list is identical for every account. So if the user's symptom is "the list still shows the previous
account's *specific* models" and another account genuinely has a different catalog, the purge cannot fix
that — there is nothing per-account to fetch. What the purge *does* fix is every per-account remnant that
actually exists today: hand-added custom entries of the old account, its model-group memberships, its
agent-loop references, its absence-grace rows, its quota/pool usage and its credential cache. If real
per-account catalogs are wanted, `WorkBuddyModelsAPI.fetchModels(accessToken:site:)` has to be implemented
(it is currently a stub returning `allModels`) — out of scope here, and I did not invent an endpoint.

### Tests

Two new checks, both wired into **both** CI workflows (`.github/workflows/ipa.yml`, `codemagic.yaml`):

`Validation/Accounts/check-workbuddy-account-switch.py` — 39 source-level static assertions:
the purge exists and really deletes by `providerInstanceId`, prunes groups/agent-loop, stamps removals,
tombstones, drops both caches, persists; it is scoped (no `removeInstance(`, no credential delete, no
`!= instanceId`); the detail view purges **inside `if success`** and **before** `refreshModels` on
WorkBuddy sign-in, and on WorkBuddy sign-out **after** the token is gone; every other provider path is
asserted to *not* contain the purge; `authRevision` wiring still present; `forgetInstance` semantics.

`tests/workbuddy_account_switch.py` — behavioural twin of the purge ported onto plain Python lists/dicts
(no Swift compiler here): removes all 4 rows of the switching instance including a `isCustom` row and an
absence-grace row; leaves the other instance's rows, group membership, agent-loop refs and tombstones
untouched; prunes + stamps; is idempotent on a second run (the refresh is detached); and §5 re-reads the
Swift body to prove each modelled step still exists, so the model cannot silently drift.

Both pass; `git diff --check` clean; every YAML parses.

**Not device-tested.** No macOS, Xcode or Swift toolchain exists in this environment: the three Swift files
were edited and brace/paren-balanced, checked by the static assertions above, but never *compiled*. Nobody
has signed in to two WorkBuddy accounts on a device with this build.

---

## TASK 2 — 开发项目 removed

Everything below was derived from a full grep (`Swift` symbols, pbxproj ids, bridging header, resources,
CI steps, docs) — nothing outside the feature was touched.

| Removed | Files / lines | Note |
|---|---|---|
| Settings entry `Section("Development")` → 开发项目 | 6 lines of `SettingsSheet.swift` | Storage section below it untouched |
| `DevelopmentProjectsView.swift` | 1 file, 28 KB | the page itself |
| `ApelinProjectAdapter.swift` | 1 file, 23 KB | editor/allowed-operations adapter |
| `ApelinModel/*` | 8 Swift files + LICENSE, 132 KB | vendored Apelin project model |
| `ApelinNative/*` | transport `.m/.h`, XPC private header, `ApelinHelloInspection.swift`, notices, 36 KB | private libSystem XPC hello |
| `ApelinTemplates/*` | 4 extensions, 244 KB | binary templates + provenance |
| `Validation/Apelin/*`, `Validation/ApelinNative/*` | ~130 files | their own harnesses/fixtures |
| `NativeCLICompile.inc` | 231 lines | compile adapter; only user was the page |
| `MinisNativeLocalToolchain`, `MinisNativeCLICompile`, `NBLocalToolchainOperation` | `NativeBuildOffload.h` | Swift-visible shims whose only caller was the page; replaced by a comment explaining why. **`native_build_offload_register()` is untouched** |
| `#import "Views/Settings/ApelinNative/MinisApelinHelloTransport.h"` | `MinisApp-Bridging-Header.h` | |
| pbxproj: 58 lines | `PBXBuildFile` ×11, `PBXFileReference` ×12, group children ×12, Sources ×12, Resources ×2 | brace/paren balanced, no orphan refs (asserted) |
| `codemagic.yaml` + `ipa.yml`: toolchain staging + "Verify provision extraction" + in-bundle unpacking + `sign_bundle_tools.py` call | ~51 + ~45 lines | see below |
| `tests/sign_bundle_tools.py`, `tests/provision_foundation.m`, `tests/provision_extract.py` | 3 files | referenced only by the removed steps |

Total: **167 files changed, 1 031 insertions(+), 16 659 deletions(-)**; 150 of them deletions.

### On-device toolchain archives — removed from the build (decision + evidence)

`MinToolchain.tgz` / `MinSDK.tgz` existed **only** for this page. Evidence:
`grep -n 'MinToolchain\|MinSDK\|NBLocalToolchainOperation'` after the removal returns the CI comment and a
`[ ! -e Payload/Minis.app/ToolchainResources ]` guard, nothing else application-side; the only Swift callers
were `DevelopmentProjectsView.swift` (`MinisNativeLocalToolchain`, `MinisNativeCLICompile`); "Build+Link"
was **inside** the removed page, not a separate feature. `NBProvisionBundledToolchain()` /
`NBExtractArchive()` in `NativeBuildProvision.m` are left in place (still compiled and reachable from the
`minis-native-build provision|doctor` guest command, which has no app-side caller) — they simply find no
archives now, which is the pre-existing "not provisioned" state.

`src/ios/ToolchainResources/` is gitignored (never in the repo). Sizes measured from the pinned release
(`native-toolchain-v1`, 4 MB chunks + final partial chunk, i.e. 10×4 MB + 998 395 B and 7×4 MB + 1 931 323 B):

* `MinSDK.tgz` ≈ **29.9 MB**
* `MinToolchain.tgz` ≈ **41.0 MB**
* total archive payload no longer downloaded, staged or packaged ≈ **70.9 MB** per build/IPA

The previous pipeline unpacked the toolchain *into* `Payload/Minis.app/Toolchain`, so the IPA also loses
roughly the uncompressed toolchain (~41 MB archive, more once expanded) on top of the 29.9 MB SDK archive;
treat **≥ 70 MB per IPA** as the conservative, archive-only figure.

### Deliberately kept (with reasons)

* `Backend/ApelinCompanion` and `Backend/ApelinFixedClient` — a companion-policy prototype and a
  fixed-client patch. **Unreferenced** by any app source, CI step or script (grep is clean). They are not
  part of the 开发项目 page, are documented NON-DEPLOYABLE, and are not compiled into the app. Removing
  them was optional in the brief; I left them so this commit does not quietly drop research the user
  never asked about. Say the word and they go in a follow-up commit.
* `Tests` / docs: `BUILDING.md`, `BUILD-READINESS.md`, `IMPLEMENTATION.md`, `REVIEW.md` still describe
  `Validation/Apelin{,Native}` scripts that no longer exist. **None of them is executed by CI** (asserted),
  so the build is unaffected. They are now stale documentation — the honest options are to delete them or
  annotate them "removed in 4f8d721"; I did not edit prose in this time-box.
* `/var/minis/shared/projects` (the directory the page wrote) and any on-device copies: **not touched**.
  The page is gone, so nothing reads them; they may contain user files.

### Verification run

```
python3 Validation/Accounts/check-workbuddy-account-switch.py      → PASS (39 assertions)
python3 tests/workbuddy_account_switch.py                          → PASS
python3 Validation/Removed/check-development-projects-removed.py    → PASS
git diff --cached --check                                          → clean
python3 -c 'yaml.safe_load(...)' codemagic.yaml / .github/workflows/ipa.yml → ok
```

`Validation/Removed/check-development-projects-removed.py` asserts that every removed path is absent, that
no scanned source/CI file still names a removed symbol (comment-only exceptions are listed explicitly),
that the pbxproj has no `D3A…` ids, no Apelin resource/build entries, **no orphan `PBXFileReference` or
`PBXBuildFile`** and balanced braces, that Settings no longer offers 开发项目, that every script path a
workflow invokes **exists**, that neither workflow stages the archives, and that
`minis-native-build` is still registered and still called from `ISHKernel.m`.

### What still references removed code

* `src/ios/NativeOffloads/NativeBuildOffload.h` — one comment naming the two Swift shims (asserted
  comment-only).
* `codemagic.yaml` — a comment naming the archives plus one negative guard
  `[ ! -e Payload/Minis.app/ToolchainResources ]` in the IPA step (so they cannot creep back).
* `src/ios/NativeOffloads/NativeBuildProvision.{h,m}` — still read `ToolchainResources/` (kept code path).
* Docs listed above (`BUILDING.md`, `BUILD-READINESS.md`, `IMPLEMENTATION.md`, `REVIEW.md`).
* Nothing else in `src/`, `Validation/`, `tests/`, `scripts/` or either workflow.

---

## Exact next steps (for the parent / user)

1. **Review locally** (nothing was pushed):
   `git -C /var/minis/workspace/fusion/ci-checkout show --stat 4f8d721`
   `git -C … diff 98b3165 4f8d721 -- src/ios/Providers src/ios/Views/Providers src/ios/Views/Settings/SettingsSheet.swift`
2. **Compile before pushing** — this is the only unverified step. On a Mac with Xcode:
   ```
   xcodebuild -project src/ios/Minis.xcodeproj -scheme Minis -configuration Debug \
     -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
   ```
   (This is also the first build that type-checks `removeAllModelEntries`, `forgetInstance` and the edited
   detail view. Expect it to either pass or point at one of those three files.)
3. **Run the new checks by hand once** (they already run first in CI):
   ```
   python3 Validation/Accounts/check-workbuddy-account-switch.py
   python3 tests/workbuddy_account_switch.py
   python3 Validation/Removed/check-development-projects-removed.py
   ```
4. **Device smoke test for Task 1** (what I could not do): sign in to WorkBuddy account A, add one custom
   model, create a group containing it → sign out → *expect zero models listed* → sign in to account B →
   *expect only B's catalog, no A entries in the picker, group no longer containing A's row, quota section
   in "loading" then B's usage*.
5. **Push and build** when 2–4 are green:
   ```
   git -C /var/minis/workspace/fusion/ci-checkout push origin apelin-integration
   ```
   then dispatch the `ipa.yml` workflow (or the Codemagic `trae-ipa` workflow). Both now start with the
   static-checks step and no longer download the 70.9 MB toolchain — expect the build to get faster and the
   IPA to shrink by ≥ 70 MB. No CI was triggered from here.
6. Optional follow-ups: delete `Backend/Apelin*`, and either delete or annotate the four stale design docs.
