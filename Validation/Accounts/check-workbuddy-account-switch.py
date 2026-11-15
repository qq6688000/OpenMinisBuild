#!/usr/bin/env python3
"""Static checks: a WorkBuddy account switch must not leave the previous
account's models behind.

STATIC ONLY. This reads source text and asserts the call order; it does not
type-check Swift or run the app. The behavioural twin (same purge modelled on
plain arrays) lives in tests/workbuddy_account_switch.py, because no compiler
exists in this environment.

What is being pinned, and why each assertion exists:

  1. `ProviderConfigStore.removeAllModelEntries(for:reason:)` exists and really
     deletes every entry of that instance (`providerInstanceId == instanceId`)
     while pruning groups / the agent-loop list and dropping the caches keyed
     by that instance (ProviderCredentialCache, QuotaStore, URLCache). If any of
     those is missing the old account's rows, group members or quota pools
     survive the switch.
  2. The purge is scoped: it must not call `removeInstance`, must not clear
     credentials, and must not touch other instances' entries.
  3. `ProviderInstanceDetailView` calls it on the WorkBuddy sign-in success
     path BEFORE `refreshModels`, and on WorkBuddy sign-out.
  4. Only WorkBuddy got the purge on sign-in — Anthropic/Gemini/Codex/Kimi/
     Copilot/Trae/Raccoon sign-ins must keep their existing behaviour, so the
     check also asserts those paths were NOT changed into purges.
  5. `authRevision` still bumps on credential change (QuotaStore's hook and the
     Providers row cache both key on it) — the purge relies on that to refresh.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
STORE = ROOT / "src/ios/Providers/ProviderConfigStore.swift"
QUOTA = ROOT / "src/ios/Providers/Quota/QuotaStore.swift"
DETAIL = ROOT / "src/ios/Views/Providers/ProviderInstanceDetailView.swift"
TYPES = ROOT / "src/ios/Providers/ProviderTypes.swift"
WORKFLOW = ROOT / "codemagic.yaml"

failures = []


def check(label, cond):
    if cond:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label}")
        failures.append(label)


def func_body(source, signature, max_lines=120):
    """Text of a Swift func from its signature to the next top-level `}`.

    Crude but sufficient: these files are written with 4-space indentation, so
    the first line that is exactly `    }` closes the declaration. `max_lines`
    bounds the scan so a miss (a `.sheet` builder, not a func) cannot swallow
    the rest of the file and falsely "contain" another branch's call.
    """
    i = source.find(signature)
    if i < 0:
        return None
    limit = i
    for _ in range(max_lines):
        nl = source.find("\n", limit)
        if nl < 0:
            break
        limit = nl + 1
    j = source.find("\n    }\n", i)
    if j < 0 or j > limit:
        return source[i:limit]
    return source[i:(j + 7)]


store = STORE.read_text()
quota = QUOTA.read_text()
detail = DETAIL.read_text()
types = TYPES.read_text()

print("[1] store API: removeAllModelEntries(for:reason:)")

purge = func_body(store, "func removeAllModelEntries(for instanceId: String")
check("removeAllModelEntries(for:reason:) is declared on the store", purge is not None)
purge = purge or ""
check("it deletes by providerInstanceId == instanceId",
      "config.modelEntries.removeAll { $0.providerInstanceId == instanceId }" in purge)
check("it prunes group members", "memberEntryIds.removeAll { doomedIds.contains($0) }" in purge)
check("it stamps per-member removal timestamps (sync-safe)",
      "removedMembers[e] = now" in purge and "addedMembers[e] = nil" in purge)
check("it prunes the agent-loop list", "config.agentLoopModelEntryIds.removeAll" in purge)
check("it tombstones the deleted entries", "recordTombstone(in: &config.deletedModelEntries" in purge)
check("it drops the credential cache for the instance",
      "ProviderCredentialCache.shared.invalidate(instanceId)" in purge)
check("it drops the quota subject/pools for the instance",
      "QuotaStore.shared.forgetInstance(instanceId)" in purge)
check("it persists (save())", re.search(r"\n\s+save\(\)", purge) is not None)

print("[2] the purge is scoped to models of ONE instance")

check("it does not delete the instance", "removeInstance(" not in purge)
check("it does not touch credentials",
      not re.search(r"(deleteOAuthToken|deleteAPIKey|deleteOAuthString|logout)\(", purge))
check("it never filters on another instance's id",
      "!= instanceId" not in purge)
check("signature is @discardableResult + returns Int",
      "@discardableResult" in store[max(0, store.find("func removeAllModelEntries") - 80):store.find("func removeAllModelEntries")]
      and ") -> Int {" in purge)

print("[3] detail view: purge before refresh on WorkBuddy sign-in")

wb_login = func_body(detail, "WorkBuddyLoginSheet(instanceId: instance.id")
check("the WorkBuddy sheet closure is found", wb_login is not None)
wb_login = wb_login or ""
check("it calls store.removeAllModelEntries(for: instance.id",
      "store.removeAllModelEntries(for: instance.id" in wb_login)
check("the purge precedes refreshModels",
      wb_login.find("removeAllModelEntries") < wb_login.find("store.refreshModels")
      if "removeAllModelEntries" in wb_login and "store.refreshModels" in wb_login else False)
check("the purge is inside the `if success` branch",
      re.search(r"if success\s*\{[^}]*removeAllModelEntries", wb_login, re.S) is not None)
check("the purge names its reason (log-friendly)",
      'reason: "workBuddy-sign-in"' in wb_login)

print("[4] detail view: purge on WorkBuddy sign-out")

logout = func_body(detail, "private func oauthLogout(_ instance: ProviderInstance)")
check("oauthLogout is found", logout is not None)
logout = logout or ""
wb_case = re.search(r"case \.workBuddy:(.*?)(?=\n        case )", logout, re.S)
check("WorkBuddy branch is separable", wb_case is not None)
wb_case_text = wb_case.group(1) if wb_case else ""
check("WorkBuddy logout still clears the token",
      "WorkBuddyOAuthManager.shared.logout(instanceId: instance.id)" in wb_case_text)
check("WorkBuddy logout purges that instance's entries",
      'store.removeAllModelEntries(for: instance.id, reason: "workBuddy-sign-out")' in wb_case_text)
check("purge happens after the token is gone",
      wb_case_text.find("WorkBuddyOAuthManager.shared.logout")
      < wb_case_text.find("removeAllModelEntries")
      if "removeAllModelEntries" in wb_case_text else False)
check("no other provider branch purges on logout",
      logout.count("removeAllModelEntries") == 1)

print("[5] other providers are untouched on sign-in")

oauth_login = func_body(detail, "private func oauthLogin(_ instance: ProviderInstance)") or ""
check("oauthLogin (added-instance / re-auth path) does not purge",
      oauth_login != "" and "removeAllModelEntries" not in oauth_login)
for sheet in ["KimiDeviceLoginSheet(instanceId: instance.id",
              "CopilotDeviceLoginSheet(instanceId: instance.id",
              "TraeLoginSheet(instanceId: instance.id",
              "RaccoonLoginSheet(instanceId: instance.id"]:
    i = detail.find(sheet)
    # The closure that follows the sheet's view builder, bounded at the first
    # line that is exactly `        }` (the sheet modifier's closing brace).
    j = detail.find("\n        }\n", i) if i >= 0 else -1
    body = detail[i:j] if i >= 0 and j > i else ""
    check(f"{sheet.split('(')[0]} sign-in does not purge",
          body != "" and "removeAllModelEntries" not in body)

print("[6] authRevision still drives the UI refresh")

check("credential writes still bump authRevision",
      "authRevision &+= 1" in store)
check("QuotaStore still observes authRevision",
      "ProviderConfigStore.shared.$authRevision.dropFirst()" in quota)
check("QuotaStore.forgetInstance exists", "func forgetInstance(_ instanceId: String)" in quota)
check("QuotaStore.forgetInstance detaches the subject and note",
      "instanceSubjects.removeValue(forKey: instanceId)" in quota
      and "instanceNotes.removeValue(forKey: instanceId)" in quota)


def quota_body(signature):
    return func_body(quota, signature) or ""


qf = quota_body("func forgetInstance(_ instanceId: String)")
check("forgetInstance drops the instance's own subject", "removeInstance(instanceId, from: sid)" in qf)
check("forgetInstance drops instance-keyed subscription subjects",
      '"instance:\\(instanceId)"' in qf)
check("forgetInstance does not remove other instances",
      "instanceSubjects.removeAll" not in qf and "watchCounts.removeAll" not in qf)

print("[7] WorkBuddy stays on the compiled-in catalog (documented limitation)")

check("WorkBuddy still has no /models discovery endpoint",
      "case .workBuddy:" in types and "oauthSupportsModelDiscovery" in types)
wb_discovery = re.search(r"case \.workBuddy:\s*//[^\n]*\n\s*return false", types)
check("ProviderType.oauthSupportsModelDiscovery(.workBuddy) == false",
      wb_discovery is not None)

print("[8] the check is wired into CI")

wf = WORKFLOW.read_text()
check("codemagic runs this check",
      "check-workbuddy-account-switch.py" in wf)

print()
if failures:
    print(f"FAIL: {len(failures)} static assertion(s) failed")
    sys.exit(1)
print("PASS: WorkBuddy account switch purges the instance's models before refresh and on sign-out; "
      "scoped to one instance; other providers unchanged (STATIC ONLY — see REPORT.md for what is "
      "not device-tested)")
