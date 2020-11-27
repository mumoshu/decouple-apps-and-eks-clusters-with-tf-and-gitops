{{/*
Expand the name of the chart.
*/}}
{{- define "clusterset-controller.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "clusterset-controller.fullname" -}}
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
{{- define "clusterset-controller.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "clusterset-controller.labels" -}}
helm.sh/chart: {{ include "clusterset-controller.chart" . }}
{{ include "clusterset-controller.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "clusterset-controller.selectorLabels" -}}
app.kubernetes.io/name: {{ include "clusterset-controller.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "clusterset-controller.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "clusterset-controller.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "clusterset-controller.leaderElectionRoleName" -}}
{{- include "clusterset-controller.fullname" . }}-leader-election
{{- end }}

{{- define "clusterset-controller.authProxyRoleName" -}}
{{- include "clusterset-controller.fullname" . }}-proxy
{{- end }}

{{- define "clusterset-controller.managerRoleName" -}}
{{- include "clusterset-controller.fullname" . }}-manager
{{- end }}

{{- define "clusterset-controller.runnerEditorRoleName" -}}
{{- include "clusterset-controller.fullname" . }}-clusterset-editor
{{- end }}

{{- define "clusterset-controller.runnerViewerRoleName" -}}
{{- include "clusterset-controller.fullname" . }}-clusterset-viewer
{{- end }}

{{- define "clusterset-controller.authProxyServiceName" -}}
{{- include "clusterset-controller.fullname" . }}-controller-manager-metrics-service
{{- end }}
