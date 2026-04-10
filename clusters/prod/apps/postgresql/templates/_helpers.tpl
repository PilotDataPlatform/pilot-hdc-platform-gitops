{{/*
Compose full image path from global registry + repository + tag
*/}}
{{- define "postgresql.initImage" -}}
{{- .Values.postgresql.global.imageRegistry }}/{{- .Values.postgresql.image.repository }}:{{- .Values.postgresql.image.tag -}}
{{- end }}
