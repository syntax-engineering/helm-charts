{{/* Context for workload helpers: dict "root" $ "name" <key> "w" <workload>. */}}

{{- define "sw.fullname" -}}
{{- .w.fullName | default (printf "%s-%s" .root.Values.app .name) -}}
{{- end }}

{{/* role is the legacy-friendly selector value; Deployment selectors are immutable. */}}
{{- define "sw.role" -}}
{{- .w.role | default .name -}}
{{- end }}

{{- define "sw.selector" -}}
app: {{ .root.Values.app }}
role: {{ include "sw.role" . }}
{{- end }}

{{/* "true" when the value is the boolean false, which turns a default off. */}}
{{- define "sw.isOff" -}}
{{- if and (kindIs "bool" .) (not .) }}true{{ end -}}
{{- end }}

{{- define "sw.resources" -}}
{{- if not (include "sw.isOff" .w.resources) -}}
{{- toYaml (mergeOverwrite (deepCopy .root.Values.defaults.resources) (.w.resources | default dict)) -}}
{{- end -}}
{{- end }}

{{/* Emits "key: value" from .from (or .default), or nothing when the value is false. */}}
{{- define "sw.opt" -}}
{{- $v := .default -}}
{{- if hasKey .from .key }}{{ $v = get .from .key }}{{ end -}}
{{- if not (include "sw.isOff" $v) }}{{ .key }}: {{ $v }}{{ end -}}
{{- end }}

{{- define "sw.container" -}}
- name: {{ .w.containerName | default (include "sw.fullname" .) }}
  image: {{ .w.image | default .root.Values.image }}
  {{- with .w.command }}
  command: {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .w.args }}
  args: {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .w.env }}
  env: {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- $envFrom := .w.envFrom | default .root.Values.envFrom }}
  {{- if or $envFrom.configMaps $envFrom.secrets }}
  envFrom:
    {{- range $envFrom.configMaps }}
    - configMapRef: { name: {{ . }} }
    {{- end }}
    {{- range $envFrom.secrets }}
    - secretRef: { name: {{ . }} }
    {{- end }}
  {{- end }}
  {{- with include "sw.resources" . }}
  resources: {{- . | nindent 4 }}
  resizePolicy:
    - { resourceName: cpu, restartPolicy: NotRequired }
    - { resourceName: memory, restartPolicy: NotRequired }
  {{- end }}
{{- end }}

{{- define "sw.podSpec" -}}
{{- with (.w.serviceAccount | default .root.Values.serviceAccount) }}
serviceAccountName: {{ . }}
{{- end }}
{{- with (.w.nodeSelector | default .root.Values.nodeSelector) }}
nodeSelector: {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .root.Values.imagePullSecret }}
imagePullSecrets:
  - name: {{ . }}
{{- end }}
containers:
{{- include "sw.container" . | nindent 2 }}
{{- end }}

{{/* Fails the render when two Deployment workloads would select the same pods. */}}
{{- define "sw.assertUniqueSelectors" -}}
{{- $seen := dict -}}
{{- range $name, $w := .Values.workloads -}}
{{- if and (has $w.kind (list "Web" "Worker")) (ne $w.enabled false) -}}
{{- $role := $w.role | default $name -}}
{{- if hasKey $seen $role -}}
{{- fail (printf "workloads %q and %q both select role=%s; give one of them a different role" $name (get $seen $role) $role) -}}
{{- end -}}
{{- $_ := set $seen $role $name -}}
{{- end -}}
{{- end -}}
{{- end }}
