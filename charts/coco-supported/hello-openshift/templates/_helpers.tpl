{{/*
Expand the name of the chart.
*/}}
{{- define "hello-openshift.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "hello-openshift.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "hello-openshift.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "hello-openshift.labels" -}}
helm.sh/chart: {{ include "hello-openshift.chart" . }}
{{ include "hello-openshift.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "hello-openshift.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hello-openshift.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Determine runtime class name from global config.
*/}}
{{- define "hello-openshift.runtimeClassName" -}}
{{- .Values.global.coco.runtimeClassName -}}
{{- end }}

{{/*
Render a workload container image; in airgap mode it is rewritten against
global.mirrorRegistry (org path included) — CoCo guest VMs pull directly,
with no IDMS/ITMS in the CVM. Guards: airgap/DEPLOY-RUNBOOK.md.
Duplicated in the three workload charts; render-gate.sh asserts sync.
*/}}
{{- define "hello-openshift.image" -}}
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
