{{/*
Common labels applied to all resources.
*/}}
{{- define "neural-gate.labels" -}}
app.kubernetes.io/name: neural-gate
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Truncate a model name to 63 chars for K8s name compliance.
*/}}
{{- define "neural-gate.modelName" -}}
{{- . | lower | replace "." "-" | replace "_" "-" | trunc 63 | trimSuffix "-" -}}
{{- end }}
