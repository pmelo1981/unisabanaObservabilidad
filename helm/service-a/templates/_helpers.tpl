{{/*
Expand the name of the chart.
*/}}
{{- define "service-a.name" -}}
{{- .Chart.Name }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "service-a.fullname" -}}
{{- printf "%s" .Chart.Name }}
{{- end }}
