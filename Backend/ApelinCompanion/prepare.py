#!/usr/bin/env python3
"""Prepare a NON-DEPLOYABLE companion source prototype; never alter upstream."""
import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

BASE = Path(__file__).resolve().parent

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('upstream', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--cdhash', required=True, help='final signed binary CDHash, not a trust assertion')
    p.add_argument('--prototype', action='store_true')
    a = p.parse_args(argv)
    if not a.prototype:
        p.error('NON-DEPLOYABLE: use --prototype only for offline inspection')
    if not re.fullmatch('[0-9a-fA-F]{40}', a.cdhash) or int(a.cdhash, 16) == 0:
        p.error('nonzero 40-hex CDHash required')
    up, out = a.upstream.resolve(), a.output.resolve()
    if out.exists() or out == up or up in out.parents:
        p.error('output must be new and outside upstream')
    manifest = json.loads((BASE.parent/'ApelinFixedClient/upstream-inputs.json').read_text())
    for name, digest in manifest.items():
        if hashlib.sha256((up/name).read_bytes()).hexdigest() != digest:
            p.error('upstream drift: '+name)
    shutil.copytree(up, out, ignore=shutil.ignore_patterns('.git', '.build', 'build', '__pycache__'))
    shim = out/'Shared/XPCShim'
    shutil.copyfile(BASE/'PeerPolicy.h', shim/'MinisPeerPolicy.h')
    (shim/'MinisPeerPin.h').write_text('#pragma once\n// Prototype only; no device trust assertion.\nstatic const unsigned char minis_expected_cdhash[20] = {' + ','.join('0x'+a.cdhash[i:i+2] for i in range(0,40,2)) + '};\n')
    # Do not replace upstream PeerAuthenticator or wire the prototype into it.
    (out/'MINIS-COMPANION.json').write_text(json.dumps({'deployable': False, 'authenticationWired': False, 'clientCDHash': a.cdhash.lower(), 'inputs': manifest}, indent=2)+'\n')
    print('NON-DEPLOYABLE source prototype; original authentication preserved; pin header generated but not wired.')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
