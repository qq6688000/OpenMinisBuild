#!/usr/bin/env python3
"""NON-DEPLOYABLE fixed-client prototype: signed-package verification is blocked."""
import argparse

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('app')
    p.add_argument('output')
    p.add_argument('--flavor', choices=['rootless', 'roothide'], required=True)
    p.add_argument('--version', default='0.1.0')
    p.parse_args(argv)
    p.error('NON-DEPLOYABLE: no trusted final signed CDHash verifier, nested signature/trust validation, or audited device identity adapter. ldid -e only extracts entitlements. No deb created. Required future order: sign complete app; verify identity and entitlements; pin final signed slice; compile/sign patched daemon; package without changing signed bytes; verify extracted archive bytes and ownership.')

if __name__ == '__main__':
    raise SystemExit(main())
