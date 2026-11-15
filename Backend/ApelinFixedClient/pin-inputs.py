#!/usr/bin/env python3
"""Maintainer-only initial pin creation; review hashes when updating upstream."""
import hashlib
import json
from pathlib import Path
import sys
up = Path(sys.argv[1])
base = Path(__file__).resolve().parent
names = ['Apelind/PeerAuthenticator.swift', 'Apelind/Spawn.swift',
         'Shared/Protocol/AppProtocol.swift', 'Apelind/Proxy/Proxy.swift',
         'Packages/ApelinKit/Sources/ApelinProtocol/Operations/SDK.swift',
         'Packages/ApelinKit/Sources/ApelinProtocol/Operations/Toolchain.swift',
         'Packages/ApelinKit/Sources/ApelinProtocol/Tasks.swift']
with (base/'upstream-inputs.json').open('x') as f:
    json.dump({n: hashlib.sha256((up/n).read_bytes()).hexdigest() for n in names}, f, indent=2)
    f.write('\n')
