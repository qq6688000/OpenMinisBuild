#!/usr/bin/env python3
"""Behavioural twin of `ProviderConfigStore.removeAllModelEntries(for:reason:)`.

No Swift compiler exists in this environment, so the purge is modelled on plain
Python lists/ dicts that mirror the production data shapes:

    entry    = {id, uuid, providerInstanceId, baseModelId, isCustom}
    group    = {id, name, memberEntryIds[], addedMembers{}, removedMembers{}}
    config   = {instances[], modelEntries[], modelGroups[], agentLoopModelEntryIds[],
                deletedModelEntries[]}

The model is written from the Swift body line by line, and [5] re-reads the
Swift source to assert the operations the model performs are still present, so
the twin cannot silently drift from the code it claims to describe.

What each scenario pins:

  [1] purging instance A removes ALL of A's entries — including custom ones and
      catalog entries the vendor stopped listing (the absence-grace rows that
      made "refreshModels" keep the previous account's models);
  [2] B keeps every entry, group member and agent-loop reference it had;
  [3] A's rows leave groups and the agent-loop list, and each removal is
      stamped so a peer's union-merge cannot add them back;
  [4] purging twice is idempotent (the sign-in path fires refreshModels
      detached, so a second purge can land mid-flight);
  [5] the Swift source still performs each modelled step.
"""
from pathlib import Path
import copy
import sys

ROOT = Path(__file__).resolve().parents[1]
STORE = ROOT / "src/ios/Providers/ProviderConfigStore.swift"

failures = 0


def check(label, cond):
    global failures
    if cond:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label}")
        failures += 1


def purge(config, instance_id):
    """Port of removeAllModelEntries(for:reason:)."""
    doomed = {e["id"] for e in config["modelEntries"] if e["providerInstanceId"] == instance_id}
    if doomed:
        config["modelEntries"] = [e for e in config["modelEntries"] if e["providerInstanceId"] != instance_id]
        for g in config["modelGroups"]:
            hit = [m for m in g["memberEntryIds"] if m in doomed]
            if not hit:
                continue
            g["memberEntryIds"] = [m for m in g["memberEntryIds"] if m not in doomed]
            for m in hit:
                g["removedMembers"][m] = "now"
                g["addedMembers"].pop(m, None)
        config["agentLoopModelEntryIds"] = [m for m in config["agentLoopModelEntryIds"] if m not in doomed]
        config["deletedModelEntries"] = list({*config["deletedModelEntries"], *doomed})
    # Cache drops are keyed by instance id and unconditional: modelled as a set.
    config.setdefault("droppedCaches", set()).add(instance_id)
    return len(doomed)


def fixture():
    def entry(i, inst, model, custom=False):
        return {"id": f"{inst}-{model}", "uuid": f"uuid-{inst}-{model}",
                "providerInstanceId": inst, "baseModelId": model, "isCustom": custom}

    return {
        "instances": ["wb", "other"],
        "modelEntries": [
            # account #1 of the WorkBuddy instance
            entry("wb", "wb", "glm-4.6"),
            entry("wb", "wb", "kimi-k2"),
            entry("wb", "wb", "my-custom-model", custom=True),
            entry("wb", "wb", "unlisted-old-model"),     # kept by the absence grace
            # a completely different provider instance
            entry("other", "other", "gpt-5"),
            entry("other", "other", "claude-opus"),
        ],
        "modelGroups": [
            {"id": "g1", "name": "Chat", "memberEntryIds": ["wb-glm-4.6", "other-gpt-5"],
             "addedMembers": {"wb-glm-4.6": "t0", "other-gpt-5": "t0"}, "removedMembers": {}},
            {"id": "g2", "name": "Other only", "memberEntryIds": ["other-claude-opus"],
             "addedMembers": {"other-claude-opus": "t0"}, "removedMembers": {}},
        ],
        "agentLoopModelEntryIds": ["wb-kimi-k2", "other-gpt-5"],
        "deletedModelEntries": [],
    }


print("[1] every entry of the switching instance is gone")

c = fixture()
before = len(c["modelEntries"])
removed = purge(c, "wb")
check("returns the number of rows it removed", removed == 4)
check("no entry with providerInstanceId == 'wb' remains",
      not [e for e in c["modelEntries"] if e["providerInstanceId"] == "wb"])
check("custom entry of the OLD account is gone too "
      "(refreshModels would have kept it)",
      "wb-my-custom-model" not in [e["id"] for e in c["modelEntries"]])
check("absence-grace row of the OLD account is gone too "
      "(refreshModels keeps it for 7 days)",
      "wb-unlisted-old-model" not in [e["id"] for e in c["modelEntries"]])
check("the model list actually shrank", len(c["modelEntries"]) == before - 4)

print("[2] the other provider instance is untouched")

check("both 'other' entries survive",
      [e["id"] for e in c["modelEntries"]] == ["other-gpt-5", "other-claude-opus"])
check("'other' keeps its group membership",
      c["modelGroups"][1]["memberEntryIds"] == ["other-claude-opus"]
      and c["modelGroups"][0]["memberEntryIds"] == ["other-gpt-5"])
check("'other' keeps its agent-loop reference",
      c["agentLoopModelEntryIds"] == ["other-gpt-5"])
check("no 'other' removal stamp was written",
      "other-gpt-5" not in c["modelGroups"][0]["removedMembers"])
check("no 'other' tombstone was written",
      all(t.startswith("wb-") for t in c["deletedModelEntries"]))

print("[3] dangling references are pruned and stamped for sync")

g1 = c["modelGroups"][0]
check("wb member removed from the shared group", "wb-glm-4.6" not in g1["memberEntryIds"])
check("removal stamped so a peer's union-merge cannot re-add it",
      g1["removedMembers"].get("wb-glm-4.6") == "now")
check("stale add stamp cleared", "wb-glm-4.6" not in g1["addedMembers"])
check("wb entry gone from the agent-loop list",
      "wb-kimi-k2" not in c["agentLoopModelEntryIds"])
check("deleted entries are tombstoned",
      set(c["deletedModelEntries"]) == {"wb-glm-4.6", "wb-kimi-k2", "wb-my-custom-model",
                                        "wb-unlisted-old-model"})
check("instance-keyed caches dropped for 'wb' only",
      c["droppedCaches"] == {"wb"})

print("[4] a second purge (detached refresh still running) is harmless")

snapshot = copy.deepcopy(c["modelEntries"]), copy.deepcopy(c["modelGroups"])
again = purge(c, "wb")
check("second purge removes nothing", again == 0)
check("entries unchanged", c["modelEntries"] == snapshot[0])
check("groups unchanged", c["modelGroups"] == snapshot[1])
check("caches still dropped for the instance", "wb" in c["droppedCaches"])

print("[5] the modelled steps still exist in the Swift source")

store = STORE.read_text()
i = store.find("func removeAllModelEntries(for instanceId: String")
body = store[i:store.find("\n    }\n", i)] if i >= 0 else ""
for label, token in [
    ("scoped entry deletion", "config.modelEntries.removeAll { $0.providerInstanceId == instanceId }"),
    ("group member prune", "memberEntryIds.removeAll { doomedIds.contains($0) }"),
    ("removal stamping", "removedMembers[e] = now"),
    ("agent-loop prune", "config.agentLoopModelEntryIds.removeAll { doomedIds.contains($0) }"),
    ("tombstones", "recordTombstone(in: &config.deletedModelEntries"),
    ("credential cache drop", "ProviderCredentialCache.shared.invalidate(instanceId)"),
    ("quota cache drop", "QuotaStore.shared.forgetInstance(instanceId)"),
    ("persistence", "save()"),
]:
    check(f"Swift still does: {label}", token in body)
check("Swift never deletes the instance itself", "removeInstance(" not in body)

print()
if failures:
    print(f"FAIL: {failures} assertion(s) failed")
    sys.exit(1)
print("PASS: account-switch purge clears exactly one instance's models (custom, unlisted and "
      "catalog), prunes and stamps its group/agent-loop references, leaves every other instance "
      "untouched, and is idempotent (MODEL ONLY — no Swift execution)")
