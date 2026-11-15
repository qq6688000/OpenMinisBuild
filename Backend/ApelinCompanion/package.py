#!/usr/bin/env python3
"""Companion packaging is disabled: no signature/trust verification exists."""
import argparse

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('prepared')
    p.add_argument('deb')
    p.add_argument('output')
    p.parse_args(argv)
    p.error('NON-DEPLOYABLE prototype: byte-search of a CDHash does not verify a signature, provenance, or identity; no package was created')

if __name__ == '__main__':
    raise SystemExit(main())
