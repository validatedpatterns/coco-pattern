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
{{- define "hello-openshift.image" -}}
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
