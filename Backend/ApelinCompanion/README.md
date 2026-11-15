# Offline companion policy prototype

NON-DEPLOYABLE. The sole candidate integration route is ../ApelinFixedClient.
This experiment does not replace or wire into upstream authentication.
`prepare.py --prototype UPSTREAM OUTPUT --cdhash HASH` verifies the fixed-client
upstream manifest, preserves the original PeerAuthenticator, and emits
Shared/XPCShim/MinisPeerPin.h plus the pure policy header for offline inspection.
No __init__.py is required: these are standalone Python 3 CLI scripts; each
importable entry point has main() and an __name__ guard. Output mode is explicitly
--prototype; generated files use normal source-file modes, not executable bits.

Run `python3 Backend/ApelinCompanion/test-policy.py` from repository root.
It compiles the actual pure C predicate with host cc and runs 34 allow/deny cases.
Those observations are fabricated test inputs, not authenticated kernel data.
The Apple adapter always denies; the previous guessed csops operation/blob parser
was removed. Local SDK symbol exports alone do not prove identity ABI or trust.
`package.py` always rejects: neither CDHash byte-search nor ldid entitlement
extraction verifies code signatures, signing identity, source provenance or trust.
No deb is produced, installed, or published. Final signing must precede any real
CDHash pin; any subsequent resigning invalidates that pin.
