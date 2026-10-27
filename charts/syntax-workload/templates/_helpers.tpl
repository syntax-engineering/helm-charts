{{/* Context for workload helpers: dict "root" $ "name" <key> "w" <workload>. */}}

{{- define "sw.fullname" -}}
{{- .w.fullName | default (printf "%s-%s" .root.Values.app .name) -}}
{{- end }}

{{/* role is the legacy-friendly selector value; Deployment selectors are immutable. */}}
{{- define "sw.role" -}}
{{- .w.role | default .name -}}
{{- end }}

{{- define "sw.selector" -}}
{{- $labels := dict "app" (.w.app | default .root.Values.app) -}}
{{- if not (include "sw.isOff" .w.role) }}{{ $_ := set $labels "role" (include "sw.role" .) }}{{ end -}}
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
  {{- if ne (dig "compat" "resizePolicy" true $.w) false }}
  resizePolicy:
    - { resourceName: cpu, restartPolicy: NotRequired }
    - { resourceName: memory, restartPolicy: NotRequired }
  {{- end }}
  {{- end }}
  {{- if and (eq .w.kind "Worker") .w.extraPorts }}
  ports:
    {{- range .w.extraPorts }}
    - { containerPort: {{ .port }}, name: {{ .name }}, protocol: TCP }
    {{- end }}
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
{{- fail (printf "the selector of workload %q would also match the pods of workload %q; give one of them a different app, role, or selectorLabels" $aname $bname) -}}
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
{{- fail (printf "CronJob workload %q has pod labels that match the selector of workload %q; give one of them a different app, role, or selectorLabels" $cname $dname) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* Ports and probes for Web containers, indented to sit under a container list item. */}}
{{- define "sw.webContainer" -}}
{{- $pname := .w.portName | default "http" }}
{{- $bare := dig "compat" "bareContainerPort" false .w }}
ports:
{{- if $bare }}
  - containerPort: {{ .w.port }}
{{- else }}
  - { containerPort: {{ .w.port }}, name: {{ $pname }}, protocol: TCP }
{{- end }}
{{- range .w.extraPorts }}
{{- if eq .name $pname }}{{ fail (printf "extraPorts entry %q reuses the port name of the main port" .name) }}{{ end }}
  - { containerPort: {{ .port }}, name: {{ .name }}, protocol: TCP }
{{- end }}
{{- if not (include "sw.isOff" .w.probes) }}
{{- $get := dict "httpGet" (dict "path" .w.healthPath "port" .w.port "scheme" "HTTP") }}
{{- $ptype := .w.probeType | default "http" }}
{{- if eq $ptype "tcp" }}
{{- $get = dict "tcpSocket" (dict "port" (ternary .w.port $pname $bare)) }}
{{- else if eq $ptype "grpc" }}
{{- $get = dict "grpc" (dict "port" .w.port) }}
{{- end }}
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

{{/* Ingress helpers take the workload context plus "key" (entry name) and "in" (entry). */}}

{{/* "name" replaces <fullname>-<entry>, so an entry can keep its objects' names when it is renamed. */}}
{{- define "sw.ingressName" -}}
{{- .in.name | default (printf "%s-%s" (include "sw.fullname" .) .key) -}}
{{- end }}

{{- define "sw.ingressService" -}}
{{- .w.serviceName | default (include "sw.fullname" .) -}}
{{- end }}

{{/* NGF defaults match the names apps already use, so migrating keeps the Gateway's load balancer and certificate. */}}
{{- define "sw.ingressTlsSecret" -}}
{{- $default := printf "%s-tls" (include "sw.ingressName" .) -}}
{{- if eq .in.backend "ngf" }}{{ $default = printf "%s-tls" .root.Values.app }}{{ end -}}
{{- dig "tls" "secretName" $default .in -}}
{{- end }}

{{- define "sw.ngfGatewayName" -}}
{{- dig "gateway" "name" (printf "%s-nginx-gateway" .root.Values.app) .in -}}
{{- end }}

{{- define "sw.ngfGatewayNamespace" -}}
{{- dig "gateway" "namespace" "nginx-gateway" .in -}}
{{- end }}

{{/*
Fails the render when two NGF entries that create a Gateway would render the
same Gateway, or would write the same TLS Secret in one namespace.
*/}}
{{- define "sw.assertUniqueGateways" -}}
{{- $gateways := dict -}}
{{- $secrets := dict -}}
{{- range $name, $w := .Values.workloads -}}
{{- if and (eq $w.kind "Web") (ne $w.enabled false) -}}
{{- range $key, $in := $w.ingress -}}
{{- if and (eq $in.backend "ngf") (ne $in.enabled false) (ne (dig "gateway" "create" true $in) false) -}}
{{- $c := dict "root" $ "name" $name "w" $w "key" $key "in" $in -}}
{{- $id := printf "%s/%s" $name $key -}}
{{- $ns := include "sw.ngfGatewayNamespace" $c -}}
{{- $gw := printf "%s/%s" $ns (include "sw.ngfGatewayName" $c) -}}
{{- $secret := printf "%s/%s" $ns (include "sw.ingressTlsSecret" $c) -}}
{{- with get $gateways $gw -}}
{{- fail (printf "ngf entries %q and %q would both render Gateway %s; set gateway.name on one of them" . $id $gw) -}}
{{- end -}}
{{- with get $secrets $secret -}}
{{- fail (printf "ngf entries %q and %q would both write TLS secret %s; set tls.secretName on one of them" . $id $secret) -}}
{{- end -}}
{{- $_ := set $gateways $gw $id -}}
{{- $_ := set $secrets $secret $id -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Fails the render when two entries of one backend would render objects with the
same name. Takes dict "root" $ "backend" <backend>.
*/}}
{{- define "sw.assertUniqueIngressNames" -}}
{{- $seen := dict -}}
{{- $root := .root -}}
{{- $backend := .backend -}}
{{- range $name, $w := $root.Values.workloads -}}
{{- if and (eq $w.kind "Web") (ne $w.enabled false) -}}
{{- range $key, $in := $w.ingress -}}
{{- if and (eq $in.backend $backend) (ne $in.enabled false) -}}
{{- $c := dict "root" $root "name" $name "w" $w "key" $key "in" $in -}}
{{- $id := printf "%s/%s" $name $key -}}
{{- $objName := include "sw.ingressName" $c -}}
{{- with get $seen $objName -}}
{{- fail (printf "%s entries %q and %q would both render objects named %s; change name on one of them" $backend . $id $objName) -}}
{{- end -}}
{{- $_ := set $seen $objName $id -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
The ACME Issuer every TLS backend renders unless tls.clusterIssuer is set.
dict "c" <ingress context> "name" <Issuer name> "namespace" <ns> "solver" <backend's solver map>.
*/}}
{{- define "sw.acmeIssuer" -}}
{{- $acme := dig "tls" "acme" (dict) .c.in -}}
{{- $solver := .solver -}}
{{- with $acme.waitInsteadOfSelfCheck }}{{ $solver = merge (dict "waitInsteadOfSelfCheck" .) $solver }}{{ end -}}
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: {{ .name }}
  namespace: {{ .namespace }}
  labels: {{- include "sw.selector" .c | nindent 4 }}
spec:
  acme:
    server: {{ $acme.server | default "https://acme-v02.api.letsencrypt.org/directory" }}
    email: {{ $acme.email | default "devops@syntaxdata.com" }}
    privateKeySecretRef: { name: {{ .name }}-account }
    solvers: {{- toYaml (list $solver) | nindent 6 }}
{{- end }}

{{/*
The cert-manager Certificate a contour entry renders, since HTTPProxy has no cert-manager shim.
dict "c" <ingress context> "name" <name> "secretName" <Secret> "issuerRef" <issuerRef map> "dnsNames" <list>.
*/}}
{{- define "sw.contourCertificate" -}}
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ .name }}
  namespace: {{ .c.root.Values.namespace }}
  labels: {{- include "sw.selector" .c | nindent 4 }}
    cert-manager.io/solver: contour
spec:
  secretName: {{ .secretName }}
  issuerRef: { kind: {{ .issuerRef.kind }}, name: {{ .issuerRef.name }} }
  dnsNames: {{- toYaml .dnsNames | nindent 4 }}
{{- end }}

{{/* A hostname as a DNS label: "*.a.example.com" -> "wildcard-a-example-com". */}}
{{- define "sw.hostLabel" -}}
{{- . | replace "*" "wildcard" | replace "." "-" -}}
{{- end }}
