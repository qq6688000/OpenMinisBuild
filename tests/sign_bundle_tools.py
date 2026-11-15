#!/usr/bin/env python3
"""Re-sign every nested Mach-O, preserving its own entitlement dictionary.
ldid extraction checks structure only; this does not establish device trust.
"""
import pathlib
import plistlib
import subprocess
import sys
import tempfile

MAGICS = {bytes.fromhex(x) for x in
          ('cffaedfe', 'feedfacf', 'cefaedfe', 'feedface',
           'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def entitlements(path):
    result = subprocess.run(['ldid', '-e', str(path)], check=True,
                            stdout=subprocess.PIPE).stdout
    return plistlib.loads(result) if result.strip() else {}


def sign(root):
    count = 0
    for path in sorted(root.rglob('*')):
        # Sign targets once; never follow a tool symlink outside the bundle.
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) not in MAGICS:
                continue
        before = entitlements(path)
        if before:
            with tempfile.NamedTemporaryFile(suffix='.plist') as ent:
                ent.write(plistlib.dumps(before)); ent.flush()
                subprocess.run(['ldid', '-S' + ent.name, str(path)], check=True)
        else:
            subprocess.run(['ldid', '-S', str(path)], check=True)
        if entitlements(path) != before:
            raise RuntimeError('entitlements changed: ' + str(path))
        count += 1
    if not count:
        raise RuntimeError('no nested Mach-O files found')
    print('Re-signed nested Mach-O files:', count,
          '(entitlements retained; device trust unverified)')


if __name__ == '__main__':
    sign(pathlib.Path(sys.argv[1]))
