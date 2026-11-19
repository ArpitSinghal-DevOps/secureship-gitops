{{- define "secureship.labels" -}}
app.kubernetes.io/name: secureship
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "secureship.selectorLabels" -}}
app.kubernetes.io/name: secureship
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
