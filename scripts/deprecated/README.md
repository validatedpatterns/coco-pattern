# Deprecated Scripts

These scripts are quarantined here pending Phase 26 hard-deletion after Phase 25 verifies
that patterns-operator 0.0.80 installs cleanly from the mirrored community catalog.

Do NOT invoke these scripts. They were workarounds for the OCI hybrid manifest bug in
patterns-operator < 0.0.80 (https://github.com/validatedpatterns/patterns-operator/issues/778).
The bug is fixed in 0.0.80 (PR #781). Phase 26 will hard-delete once Phase 25 confirms 0.0.80.

| Script | Original Purpose | Obsoleted By |
|--------|-----------------|--------------|
| fix-patterns-operator-images.sh | Patch CSV relatedImages with amd64 digests | patterns-operator 0.0.80 (PR #781) |
| rebuild-patterns-operator-bundle.sh | Rebuild OLM bundle with amd64-only digests | patterns-operator 0.0.80 (PR #781) |
| deploy-pattern-without-operator.sh | Bypass patterns-operator entirely | patterns-operator 0.0.80 (PR #781) |

Quarantined: Phase 24 (2026-08-10). Hard-delete target: Phase 26.
