{{/* The service's name: the release name, e.g. orders. */}}
{{- define "service.name" -}}
{{ .Release.Name }}
{{- end }}

{{/*
Labels a Deployment selects its pods by. A Deployment's selector cannot change
once it exists, so only labels that never change belong here.
*/}}
{{- define "service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "service.name" . }}
{{- end }}

{{/* Labels for every object's metadata. */}}
{{- define "service.labels" -}}
{{ include "service.selectorLabels" . }}
app.kubernetes.io/part-of: ticketdrop
{{- end }}

{{/* Image reference; the repository defaults to ticketdrop/<name>. */}}
{{- define "service.image" -}}
{{ .Values.image.repository | default (printf "ticketdrop/%s" (include "service.name" .)) }}:{{ .Values.image.tag }}
{{- end }}
