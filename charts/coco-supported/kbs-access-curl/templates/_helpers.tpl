{{/*
Render a workload container image; in airgap mode it is rewritten against
global.mirrorRegistry (org path included) — CoCo guest VMs pull directly,
with no IDMS/ITMS in the CVM. Guards: airgap/DEPLOY-RUNBOOK.md.
Duplicated in the three workload charts; render-gate.sh asserts sync.
*/}}
{{- define "kbs-access-curl.image" -}}
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
