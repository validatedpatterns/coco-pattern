{{/*
Render a workload container image for the CoCo test workloads.

CoCo guest VMs pull their images directly — there is no IDMS/ITMS inside the
CVM, so a registry.redhat.io/ubi9/... reference cannot be redirected at pull
time. In airgap mode (global.airgap: true) the image is rewritten against
global.mirrorRegistry using the oc-mirror source-path convention: the registry
hostname is stripped and the mirror root prefixed, e.g.

  registry.redhat.io/ubi9/httpd-24@sha256:...
    → quay.example:443/mirror/ubi9/httpd-24@sha256:...

The mirror root must include the org path for Quay targets (it is the same
value oc-mirror was pointed at). Rendering fails fast when airgap mode is on
and the mirror is unset or still a placeholder — a missing value here would
otherwise surface as ImagePullBackOff inside the CVM minutes later.
*/}}
{{- define "kbs-access-curl.image" -}}
{{- $image := .image -}}
{{- if .root.Values.global.airgap -}}
{{- $mirror := .root.Values.global.mirrorRegistry | default "" -}}
{{- if or (not $mirror) (contains "MIRROR_REGISTRY_HOST" $mirror) -}}
{{- fail "global.mirrorRegistry must be set to the mirror root (e.g. quay.example:443/mirror) when global.airgap is true" -}}
{{- end -}}
{{- $path := regexReplaceAll "^[a-zA-Z0-9.-]+(:[0-9]+)?/(.*)$" $image "${2}" -}}
{{- printf "%s/%s" $mirror $path -}}
{{- else -}}
{{- $image -}}
{{- end -}}
{{- end -}}
