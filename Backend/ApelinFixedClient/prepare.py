#!/usr/bin/env python3
"""Emit a reviewable upstream patch; never change upstream or install anything."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent
PEER = 'Apelind/PeerAuthenticator.swift'
OLD = '''        return AppProtocol.clientPaths.contains { canonicalPath((installRoot == "/" ? "" : installRoot) + $0) == path }
            && isRootOwnedExecutable(path)'''
NEW = '''        let prefix = installRoot == "/" ? "" : installRoot
        let originalClient = AppProtocol.clientPaths.contains { canonicalPath(prefix + $0) == path }
        // This fixed package identity is additional to ALL original audit/entitlement checks.
        let minisClient = canonicalPath(prefix + "/Applications/Minis.app/Minis") == path
            && hasEntitlement("com.openminis.apelin.client", token: &token)
        return (originalClient || minisClient) && isRootOwnedExecutable(path)'''

def patch(upstream):
    pins = json.loads((BASE / 'upstream-inputs.json').read_text())
    for name, digest in pins.items():
        if hashlib.sha256((upstream / name).read_bytes()).hexdigest() != digest:
            raise ValueError('upstream drift: ' + name)
    source = (upstream / PEER).read_text()
    if source.count(OLD) != 1:
        raise ValueError('authentication anchor mismatch')
    changed = source.replace(OLD, NEW)
    return ''.join(difflib.unified_diff(source.splitlines(True), changed.splitlines(True),
        fromfile='a/' + PEER, tofile='b/' + PEER))

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('upstream', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    result = patch(a.upstream)
    with a.output.open('x') as f:
        f.write(result)
    print('Patch emitted; upstream and device unchanged.')
