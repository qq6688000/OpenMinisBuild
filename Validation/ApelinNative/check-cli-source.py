#!/usr/bin/env python3
"""Static wiring checks complement actual cross ABI and process tests."""
from pathlib import Path
r=Path(__file__).resolve().parents[2]
n=r/'src/ios/NativeOffloads'
m=(n/'NativeCLICompile.inc').read_text()
s=(r/'src/ios/Views/Settings/ApelinProjectAdapter.swift').read_text().split('enum DevelopmentCLICompileInput {',1)[1]
u=(r/'src/ios/Views/Settings/DevelopmentProjectsView.swift').read_text()
assert '#include "NativeCLICompile.inc"' in (n/'NativeBuildOffload.m').read_text()
assert '#import "NativeBuildOffload.h"' in (r/'src/ios/MinisApp-Bridging-Header.h').read_text()
for token in ['NBPRun(', 'NBMachOInspect(artifact)', 'NBP_CANCELLED', 'NBP_TIMED_OUT', 'atomic_load', 'atomic_store', '.envp=env', '.timeout_ms=120000', '.terminate_grace_ms=250', '131072', 'NBSDKRoot()', 'Foundation.framework/Headers/Foundation.h', '@"object"', '@"arm64"', '@"signed":@NO', '@"installed":@NO']:
    assert token in m,token
for token in ['DevelopmentProjectEditing.parent', 'DevelopmentProjectEditing.readAt', 'ApelinProjectAdapter.validate', 'ProjectValidation.load', 'compiles == [.compile(product: "tool", flags: [])]', 'names == ["main.m"]', 'record["target"] as? String == "ios"']:
    assert token in s,token
for token in ['Button("Build+Link · ObjC CLI")', 'native.compile(source:', 'native.cancel()', '.disabled(build.running || local.running || !local.canBuild)', 'build.cancel()', 'DevelopmentCLICompileInput.snapshot']:
    assert token in u,token
for token in ['system(', 'popen(', 'execve(', '/bin/sh', 'ISHShellExecutor', 'ldid', 'xpc_connection']:
    assert token not in m,token
print('PASS: structured compile adapter/UI, bounded source validation/logs, cancellation, fixed argv and Mach-O artifact gate (STATIC ONLY)')
