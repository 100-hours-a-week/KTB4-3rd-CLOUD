{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.name }}
{{- end }}

{{- define "app.labels" -}}
{{ include "app.selectorLabels" . }}
app.kubernetes.io/part-of: moyeota-v3
stage: {{ .Values.stage }}
{{- end }}
