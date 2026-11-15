#!/usr/bin/env python3
"""Static guard: the 开发项目 (Development Projects) feature stays removed.

Why this file exists rather than "just deleting things": the removal spans the
Xcode project, the bridging header, an Objective-C registration, two CI
workflows and a couple of hundred vendored files. Any one of them coming back
half-way (a PBXFileReference with no file, a Swift symbol whose header is gone,
a workflow step whose script no longer exists) is a red build, and the failure
message points at the symptom, not at the leftover. This check names the
leftover.

Run: python3 Validation/Removed/check-development-projects-removed.py
Exits 0 when everything is gone, 1 otherwise.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
failures = []


def check(label, cond):
    if cond:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label}")
        failures.append(label)


# Paths the feature owned. Every one must be absent from the working tree.
REMOVED_PATHS = [
    "src/ios/Views/Settings/DevelopmentProjectsView.swift",
    "src/ios/Views/Settings/ApelinProjectAdapter.swift",
    "src/ios/Views/Settings/ApelinModel",
    "src/ios/Views/Settings/ApelinNative",
    "src/ios/Views/Settings/ApelinTemplates",
    "src/ios/NativeOffloads/NativeCLICompile.inc",
    "Validation/Apelin",
    "Validation/ApelinNative",
    "tests/provision_extract.py",
    "tests/provision_foundation.m",
    "tests/sign_bundle_tools.py",
]

# Symbols / strings that must not survive anywhere in source or CI config.
FORBIDDEN = [
    "DevelopmentProjectsView",
    "ApelinProjectAdapter",
    "ApelinHelloInspection",
    "MinisApelinHelloTransport",
    "MinisApelinXPCPrivate",
    "MinisNativeLocalToolchain",
    "MinisNativeCLICompile",
    "NBLocalToolchainOperation",
    "ApelinTemplates",
    "apelin-project.json",
    "Validation/Apelin",
    "Validation/ApelinNative",
]

SCAN_SUFFIXES = {".swift", ".m", ".mm", ".c", ".h", ".inc", ".pbxproj", ".yml",
                 ".yaml", ".py", ".sh", ".plist", ".json", ".xcscheme", ".entitlements"}
SKIP_DIRS = {"deps", ".git", "build", "Backend", "__pycache__"}
# This file and REPORT.md may talk ABOUT the removed names.
SELF_SKIP = {"check-development-projects-removed.py"}

# Exact files allowed to keep a name because they mention it in a comment
# explaining the removal (`NativeBuildOffload.h` documents why the shims are
# gone). The token still may not appear as code there — see `comment_only`.
COMMENT_ONLY_OK = {"NativeBuildOffload.h"}

# The Backend/Apelin* prototypes are deliberately kept: they are unreferenced
# by this task's scope, documented NON-DEPLOYABLE, and not part of the app.
# Excluded above via SKIP_DIRS so "no references" stays meaningful.

print("[1] feature paths are gone from the working tree")

for rel in REMOVED_PATHS:
    check(f"absent: {rel}", not (ROOT / rel).exists())

print("[2] no source/CI file still names a removed symbol or path")

hits = []
for path in ROOT.rglob("*"):
    if not path.is_file() or path.suffix not in SCAN_SUFFIXES:
        continue
    parts = set(path.relative_to(ROOT).parts)
    if parts & SKIP_DIRS or path.name in SELF_SKIP:
        continue
    try:
        text = path.read_text(errors="ignore")
    except OSError:
        continue
    for token in FORBIDDEN:
        if token not in text:
            continue
        if path.name in COMMENT_ONLY_OK:
            # Every occurrence must be on a comment line.
            bad = [ln for ln in text.splitlines() if token in ln and not ln.lstrip().startswith(("*", "//", "/*"))]
            if not bad:
                continue
        hits.append(f"{path.relative_to(ROOT)}: {token}")

check("no dangling symbol/path reference"
      + ("" if not hits else "\n       " + "\n       ".join(hits)), not hits)

print("[3] Xcode project stays consistent")

pbx = (ROOT / "src/ios/Minis.xcodeproj/project.pbxproj").read_text()
check("no D3A-prefixed (feature) object ids", "D3A" not in pbx)
check("no Apelin resource folder in Resources",
      not re.search(r"Apelin\w* in Resources", pbx))
check("no Development/Apelin Swift in Sources",
      not re.search(r"(DevelopmentProjectsView|Apelin\w+)\.swift in Sources", pbx))
# Every PBXFileReference id must still be used somewhere else in the file
# (group children or a build file), otherwise Xcode shows a phantom file.
refs = set(re.findall(r"^\s+([0-9A-F]{24})[^=]*= \{isa = PBXFileReference", pbx, re.M))
orphans = [r for r in refs if len(re.findall(re.escape(r), pbx)) < 2]
check("no orphan PBXFileReference" + ("" if not orphans else f": {orphans[:5]}"),
      not orphans)
builds = set(re.findall(r"^\s+([0-9A-F]{24})[^=]*= \{isa = PBXBuildFile", pbx, re.M))
orphan_builds = [b for b in builds if len(re.findall(re.escape(b), pbx)) < 2]
check("no orphan PBXBuildFile" + ("" if not orphan_builds else f": {orphan_builds[:5]}"),
      not orphan_builds)
check("project braces balanced", pbx.count("{") == pbx.count("}"))

print("[4] the Settings page no longer offers it")

settings = (ROOT / "src/ios/Views/Settings/SettingsSheet.swift").read_text()
check("no '开发项目' label", "开发项目" not in settings)
check("no Section(\"Development\")", 'Section("Development")' not in settings)
check("Storage section still present", "StorageManagementView()" in settings)

print("[5] CI does not run a deleted script")

for wf in [ROOT / "codemagic.yaml", ROOT / ".github/workflows/ipa.yml"]:
    text = wf.read_text()
    name = wf.relative_to(ROOT)
    # `#`-prefixed lines are comments (the removal notes name the archives they
    # mention); only executable lines are checked.
    for line in [l for l in text.splitlines() if not l.lstrip().startswith("#")]:
        m = re.search(r"(?:sh |python3 )((?:Validation|tests|scripts)/\S+\.(?:sh|py))", line)
        if m:
            check(f"{name} references an existing script: {m.group(1)}",
                  (ROOT / m.group(1)).exists())
    commands = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
    check(f"{name} does not stage the removed toolchain",
          "MinToolchain.tgz" not in commands and "MinSDK.tgz" not in commands)

print("[6] the native handler this feature touched still registers")

offload = (ROOT / "src/ios/NativeOffloads/NativeBuildOffload.m").read_text()
check("no CLI compile adapter include", '#include "NativeCLICompile.inc"' not in offload)
check("minis-native-build still registered",
      'native_offload_add_handler("minis-native-build",nb_handler)' in offload)
kernel = (ROOT / "src/ios/iSH/ISHKernel.m").read_text()
check("iSHKernel still calls native_build_offload_register()",
      "native_build_offload_register();" in kernel)

print()
if failures:
    print(f"FAIL: {len(failures)} leftover(s)")
    sys.exit(1)
print("PASS: 开发项目 feature fully removed — no paths, symbols, Xcode objects, Settings entry "
      "or CI step remain, and the unrelated minis-native-build handler still registers")
