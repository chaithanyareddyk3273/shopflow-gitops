{{/* Labels shared by every resource. Call with (dict "root" $ "name" "<component>") */}}
{{- define "shopflow.labels" -}}
{{ include "shopflow.selectorLabels" . }}
app.kubernetes.io/part-of: shopflow
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version }}
{{- end }}

{{/* Immutable selector labels (must never change after the first install) */}}
{{- define "shopflow.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}

{{/* Restrictive container security context reused by the app services */}}
{{- define "shopflow.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}

{{/* podSelector matching one component by name, e.g. "postgres" (used by NetworkPolicies) */}}
{{- define "shopflow.podSelector" -}}
podSelector:
  matchLabels:
    app.kubernetes.io/name: {{ . }}
{{- end }}
