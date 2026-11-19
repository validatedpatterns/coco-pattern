# Disconnected (Airgap) Deployment

This guide has been superseded by the airgap deployment runbook:
[airgap/DEPLOY-RUNBOOK.md](../airgap/DEPLOY-RUNBOOK.md). The runbook tracks
the current OpenShift 4.22 flow, the value-delta convention (the committed
tree stays a working connected install; every disconnected delta is a
deploy-branch value change), and the bootstrap-time validation in
`scripts/airgap-post-install.sh`.

## Why this page was retired

The content here had drifted from the repository:

- 4.21-era catalog names (`cs-*-index-v4-21`) that no longer match the
  mirrored 4.22 operator indexes
- references to `airgap/imageset-config.yaml`, a path that does not exist
  (the imageset is `airgap/imageset-config-4.22.yaml`)
- make targets that did not exist at the time of writing
- a `gitops.channel: latest` example that does not match the mirrored
  `gitops-1.22` channel
- pre-rewrite manual image-override instructions — the workload charts now
  rewrite their images against `global.mirrorRegistry` in airgap mode
