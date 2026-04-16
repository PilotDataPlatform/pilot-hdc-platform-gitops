{{/*
Common labels
*/}}
{{- define "jupyterhub-stack.labels" -}}
helm.sh/chart: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
