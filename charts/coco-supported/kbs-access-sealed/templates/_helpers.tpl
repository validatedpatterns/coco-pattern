{{/*
Render a workload container image for the CoCo test workloads.

CoCo guest VMs pull their images directly — there is no IDMS/ITMS inside the
CVM, so a registry.redhat.io/ubi9/... reference cannot be redirected at pull
time. In airgap mode (global.airgap: true) the image is rewritten against
global.mirrorRegistry using the oc-mirror source-path convention: the registry
hostname is stripped and the mirror root prefixed, e.g.

  registry.redhat.io/ubi9/httpd-24@sha256:...
    → quay.example.com:443/mirror/ubi9/httpd-24@sha256:...

The mirror root must include the org path for Quay targets (it is the same
value oc-mirror was pointed at). Three guards:

  - an image ALREADY under the mirror root is returned unchanged (otherwise
    it would be double-prefixed: .../mirror/mirror/ubi9/...);
  - the host is only stripped when the first segment actually looks like one
    (contains "." or ":", or is "localhost") — a hostless reference such as
    library/httpd:2.4 keeps its org segment;
  - rendering fails fast when airgap mode is on and the mirror is unset or a
    placeholder — a missing value here would otherwise surface as
    ImagePullBackOff inside the CVMs minutes later.

This helper is duplicated verbatim in hello-openshift, kbs-access-curl and
kbs-access-sealed (path-rendered charts cannot share a library template);
scripts/verify/render-gate.sh asserts the copies stay identical.
*/}}
{{- define "kbs-access-sealed.image" -}}
{{- $image := .image -}}
{{- if .root.Values.global.airgap -}}
{{- $mirror := .root.Values.global.mirrorRegistry | default "" -}}
{{- if or (not $mirror) (contains "__MIRROR_REGISTRY__" $mirror) (contains "MIRROR_REGISTRY_HOST" $mirror) -}}
{{- fail "global.mirrorRegistry must be set to the mirror root (e.g. quay.example.com:443/mirror) when global.airgap is true" -}}
{{- end -}}
{{- if hasPrefix (printf "%s/" $mirror) $image -}}
{{- $image -}}
{{- else -}}
{{- $host := regexFind "^[^/]+" $image -}}
{{- if or (contains "." $host) (contains ":" $host) (eq $host "localhost") -}}
{{- printf "%s/%s" $mirror (regexReplaceAll "^[^/]+/(.*)$" $image "${1}") -}}
{{- else -}}
{{- printf "%s/%s" $mirror $image -}}
{{- end -}}
{{- end -}}
{{- else -}}
{{- $image -}}
{{- end -}}
{{- end -}}
