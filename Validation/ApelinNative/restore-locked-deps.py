#!/usr/bin/env python3
"""Recover top-level gitlinks for archive users; never overwrite nonempty dirs."""
from pathlib import Path
import hashlib, io, os, tarfile, tempfile, urllib.request
ROOT = Path(__file__).resolve().parents[2]
LOCKS = (
    ('ish', 'OpenMinis/ish-arm64', '0fd17a135e78b7a0cf08a4f5831217bbb76ed22f', 'd26a47031c8ecf306e5c2c20989549be2383100c051c25cd0adab8d6e5c8e526'),
    ('proot', 'OpenMinis/proot', '8b31a69345730692f2f49a88694fdcaec78b2031', 'e8fb7d261bf1e9ff362f46b75136c32ae62ae4b5cb17f8cc7d2bfd11a487f7fe'),
)
for name, repo, sha, digest in LOCKS:
    dest = ROOT / 'deps' / name
    with urllib.request.urlopen(f'https://codeload.github.com/{repo}/tar.gz/{sha}', timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != digest:
        raise SystemExit(f'{name}: archive hash mismatch; review provenance before proceeding')
    with tempfile.TemporaryDirectory(prefix=f'{name}-', dir=ROOT / 'deps') as work:
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            archive.extractall(work, filter='data')  # Python 3.12+ recommended
        source, = Path(work).iterdir()
        if dest.is_symlink():
            raise SystemExit(f'{dest}: refusing symlink destination')
        if dest.exists() and any(dest.iterdir()):
            # Verify archive members without deleting or replacing local changes.
            for p in source.rglob('*'):
                other = dest / p.relative_to(source)
                same = (other.is_symlink() and os.readlink(other) == os.readlink(p)) if p.is_symlink() else ((other.is_file() and not other.is_symlink() and other.read_bytes() == p.read_bytes()) if p.is_file() else other.is_dir())
                if not same:
                    raise SystemExit(f'{other}: local difference; snapshot and reconcile manually')
            print(f'VERIFIED {name}@{sha}; existing contents preserved (extra local files retained)')
        else:
            if dest.exists():
                dest.rmdir()
            source.rename(dest)
            print(f'RESTORED {name}@{sha}')
print('Top-level sources only. Nested iSH gitlinks and generated headers remain separate prerequisites; see BUILD-READINESS.md.')
