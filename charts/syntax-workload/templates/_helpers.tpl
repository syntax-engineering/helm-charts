{{/* Context for workload helpers: dict "root" $ "name" <key> "w" <workload>. */}}

{{- define "sw.fullname" -}}
{{- .w.fullName | default (printf "%s-%s" .root.Values.app .name) -}}
{{- end }}

{{/* role is the legacy-friendly selector value; Deployment selectors are immutable. */}}
{{- define "sw.role" -}}
{{- .w.role | default .name -}}
{{- end }}

{{- define "sw.selector" -}}
{{- $labels := dict "app" .root.Values.app "role" (include "sw.role" .) -}}
{{- toYaml (merge $labels (.w.selectorLabels | default dict)) -}}
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
  {{- with .w.volumeMounts }}
  volumeMounts: {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with include "sw.resources" . }}
  resources: {{- . | nindent 4 }}
  resizePolicy:
    - { resourceName: cpu, restartPolicy: NotRequired }
    - { resourceName: memory, restartPolicy: NotRequired }
  {{- end }}
  {{- if eq .w.kind "Web" }}
  {{- include "sw.webContainer" . | nindent 2 }}
  {{- end }}
{{- end }}

{{- define "sw.podSpec" -}}
{{- with (.w.serviceAccount | default .root.Values.serviceAccount) }}
serviceAccountName: {{ . }}
{{- end }}
{{- with (.w.nodeSelector | default .root.Values.nodeSelector) }}
nodeSelector: {{- toYaml . | nindent 2 }}
{{- end }}
{{- $priority := .root.Values.priorityClassName }}
{{- if hasKey .w "priorityClassName" }}{{ $priority = .w.priorityClassName }}{{ end }}
{{- if and $priority (not (include "sw.isOff" $priority)) }}
priorityClassName: {{ $priority | quote }}
{{- end }}
{{- with .root.Values.imagePullSecret }}
imagePullSecrets:
  - name: {{ . }}
{{- end }}
containers:
{{- include "sw.container" . | nindent 2 }}
{{- with .w.volumes }}
volumes: {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Fails the render when pods could be selected by the wrong workload. Rules:
- For any two enabled Web/Worker workloads, one selector must not be a subset of
  the other (this includes equal selectors). Pod labels equal the selector, so a
  subset selector would also match the other workload's pods.
- A CronJob's pod labels must not match (be a superset of) any enabled
  Web/Worker selector.
- CronJobs may share a selector with each other. Hooks carry no labels.
*/}}
{{- define "sw.assertUniqueSelectors" -}}
{{- $deployments := dict -}}
{{- $crons := dict -}}
{{- range $name, $w := .Values.workloads -}}
{{- if ne $w.enabled false -}}
{{- if has $w.kind (list "Web" "Worker") -}}
{{- $_ := set $deployments $name (fromYaml (include "sw.selector" (dict "root" $ "name" $name "w" $w))) -}}
{{- else if eq $w.kind "CronJob" -}}
{{- $_ := set $crons $name (fromYaml (include "sw.selector" (dict "root" $ "name" $name "w" $w))) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $aname, $asel := $deployments -}}
{{- range $bname, $bsel := $deployments -}}
{{- if ne $aname $bname -}}
{{- $match := dict "all" true -}}
{{- range $k, $v := $asel -}}
{{- if ne (get $bsel $k) $v -}}{{- $_ := set $match "all" false -}}{{- end -}}
{{- end -}}
{{- if get $match "all" -}}
{{- fail (printf "the selector of workload %q would also match the pods of workload %q; give one of them a different role or selectorLabels" $aname $bname) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $cname, $labels := $crons -}}
{{- range $dname, $sel := $deployments -}}
{{- $match := dict "all" true -}}
{{- range $k, $v := $sel -}}
{{- if ne (get $labels $k) $v -}}{{- $_ := set $match "all" false -}}{{- end -}}
{{- end -}}
{{- if get $match "all" -}}
{{- fail (printf "CronJob workload %q has pod labels that match the selector of workload %q; give one of them a different role or selectorLabels" $cname $dname) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* Ports and probes for Web containers, indented to sit under a container list item. */}}
{{- define "sw.webContainer" -}}
ports:
{{- if dig "compat" "bareContainerPort" false .w }}
  - containerPort: {{ .w.port }}
{{- else }}
  - { containerPort: {{ .w.port }}, name: http, protocol: TCP }
{{- end }}
{{- if not (include "sw.isOff" .w.probes) }}
{{- $get := dict "httpGet" (dict "path" .w.healthPath "port" .w.port "scheme" "HTTP") }}
{{- $defaults := dict
  "startupProbe" (merge (dict "failureThreshold" 60 "periodSeconds" 5 "timeoutSeconds" 3) $get)
  "readinessProbe" (merge (dict "failureThreshold" 2 "periodSeconds" 3 "successThreshold" 1 "timeoutSeconds" 1) $get)
  "livenessProbe" (merge (dict "failureThreshold" 6 "periodSeconds" 10 "timeoutSeconds" 5) $get) }}
{{- $keys := dict "startupProbe" "startup" "readinessProbe" "readiness" "livenessProbe" "liveness" }}
{{- $overrides := .w.probes | default dict }}
{{- range $field := list "startupProbe" "readinessProbe" "livenessProbe" }}
{{- $o := get $overrides (get $keys $field) }}
{{- if not (include "sw.isOff" $o) }}
{{ $field }}: {{- toYaml (mergeOverwrite (deepCopy (get $defaults $field)) ($o | default dict)) | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
