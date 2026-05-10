{{/*
site helpers.

Most naming and labeling work goes through `bitnami/common`'s helpers
(`common.names.fullname`, `common.labels.standard`, `common.images.image`,
`common.tplvalues.render`, etc.). The wrappers below resolve names of
peer resources (DB, cache, S3) so subchart-vs-external can be one
template change.
*/}}

{{/*
Image reference. Honors the `image.digest` precedence over `image.tag`.
*/}}
{{- define "site.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global "chart" .Chart) }}
{{- end -}}

{{/*
Name of the keys+salts Secret. Auto-generated default, or an existing one.
*/}}
{{- define "site.secretName" -}}
{{- if .Values.keysSalts.existingSecret -}}
{{ tpl .Values.keysSalts.existingSecret . }}
{{- else -}}
{{ printf "%s-keys" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{- end -}}

{{/*
Name of the Secret carrying admin install credentials (auto-generated
default, or an existing one provided by the operator).
*/}}
{{- define "site.siteInstallSecretName" -}}
{{- if .Values.siteInstall.existingSecret -}}
{{ tpl .Values.siteInstall.existingSecret . }}
{{- else -}}
{{ printf "%s-install" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{- end -}}

{{/*
Key inside the install Secret holding the admin username. Auto-generated
Secrets always use the canonical `admin_user`; existing Secrets use the
configured key.
*/}}
{{- define "site.siteInstallAdminUserKey" -}}
{{- if .Values.siteInstall.existingSecret -}}
{{ .Values.siteInstall.existingSecretAdminUserKey | default "admin_user" }}
{{- else -}}admin_user{{- end -}}
{{- end -}}

{{- define "site.siteInstallAdminEmailKey" -}}
{{- if .Values.siteInstall.existingSecret -}}
{{ .Values.siteInstall.existingSecretAdminEmailKey | default "admin_email" }}
{{- else -}}admin_email{{- end -}}
{{- end -}}

{{- define "site.siteInstallAdminPasswordKey" -}}
{{- if .Values.siteInstall.existingSecret -}}
{{ .Values.siteInstall.existingSecretAdminPasswordKey | default "admin_password" }}
{{- else -}}admin_password{{- end -}}
{{- end -}}

{{/*
Database host. When the in-chart MariaDB subchart is enabled, the
`<release>-mariadb` service is the canonical Service name for bitnami/mariadb
(the subchart's own `common.names.fullname` produces `<release>-mariadb`,
not `<release>-<our-chart-name>-mariadb`).
*/}}
{{- define "site.databaseHost" -}}
{{- if .Values.mariadb.enabled -}}
{{ printf "%s-mariadb" .Release.Name }}
{{- else -}}
{{ .Values.externalDatabase.host }}
{{- end -}}
{{- end -}}

{{- define "site.databasePort" -}}
{{- if .Values.mariadb.enabled -}}3306{{- else -}}{{ .Values.externalDatabase.port }}{{- end -}}
{{- end -}}

{{- define "site.databaseName" -}}
{{- if .Values.mariadb.enabled -}}{{ .Values.mariadb.auth.database }}{{- else -}}{{ .Values.externalDatabase.database }}{{- end -}}
{{- end -}}

{{- define "site.databaseUser" -}}
{{- if .Values.mariadb.enabled -}}{{ .Values.mariadb.auth.username }}{{- else -}}{{ .Values.externalDatabase.user }}{{- end -}}
{{- end -}}

{{/*
Name of the Secret holding the DB password (subchart-managed or external).
*/}}
{{- define "site.databaseSecretName" -}}
{{- if .Values.mariadb.enabled -}}
{{ printf "%s-mariadb" .Release.Name }}
{{- else if .Values.externalDatabase.existingSecret -}}
{{ tpl .Values.externalDatabase.existingSecret . }}
{{- else -}}
{{ printf "%s-db" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{- end -}}

{{- define "site.databaseSecretPasswordKey" -}}
{{- if .Values.mariadb.enabled -}}
mariadb-password
{{- else -}}
{{ .Values.externalDatabase.existingSecretPasswordKey | default "password" }}
{{- end -}}
{{- end -}}

{{/*
Cache (Redis-compatible) host.
*/}}
{{- define "site.cacheHost" -}}
{{- if .Values.redis.enabled -}}
{{ printf "%s-redis-master" .Release.Name }}
{{- else -}}
{{ .Values.externalCache.host }}
{{- end -}}
{{- end -}}

{{- define "site.cachePort" -}}
{{- if .Values.redis.enabled -}}6379{{- else -}}{{ .Values.externalCache.port }}{{- end -}}
{{- end -}}

{{- define "site.cacheUrl" -}}
{{- printf "%s:%s" (include "site.cacheHost" .) (include "site.cachePort" .) -}}
{{- end -}}

{{/*
S3 endpoint host. For in-chart MinIO, point at the subchart's Service.
*/}}
{{- define "site.s3Endpoint" -}}
{{- if .Values.minio.enabled -}}
{{ printf "http://%s-minio:9000" .Release.Name }}
{{- else -}}
{{ .Values.externalS3.endpoint }}
{{- end -}}
{{- end -}}

{{- define "site.s3Bucket" -}}
{{- if .Values.minio.enabled -}}
{{ .Values.minio.defaultBuckets | default "site-media" }}
{{- else -}}
{{ .Values.externalS3.bucket }}
{{- end -}}
{{- end -}}

{{- define "site.s3Region" -}}
{{- if .Values.minio.enabled -}}us-east-1{{- else -}}{{ .Values.externalS3.region }}{{- end -}}
{{- end -}}

{{/*
Name of the Secret holding S3 access keys.
*/}}
{{- define "site.s3SecretName" -}}
{{- if .Values.minio.enabled -}}
{{ printf "%s-minio" .Release.Name }}
{{- else if .Values.externalS3.existingSecret -}}
{{ tpl .Values.externalS3.existingSecret . }}
{{- else -}}
{{ printf "%s-s3" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{- end -}}

{{- define "site.s3AccessKeyKey" -}}
{{- if .Values.minio.enabled -}}root-user{{- else -}}access-key{{- end -}}
{{- end -}}

{{- define "site.s3SecretKeyKey" -}}
{{- if .Values.minio.enabled -}}root-password{{- else -}}secret-key{{- end -}}
{{- end -}}

{{/*
SMTP env entries from a Secret.

When `smtp.enabled=true` AND `smtp.auth.existingSecret` is set, emit the
two `secretKeyRef` env entries. Used identically by the Deployment, the
wpcron CronJob, and the install Job — keeps the three workloads in sync.

When `smtp.enabled=false`, this expands to nothing — `FP_SMTP_HOST`
isn't injected by the configmap either, so the SMTPMailer mu-plugin
component sees no host and is a silent no-op.
*/}}
{{- define "site.smtpEnvFromSecret" -}}
{{- if and .Values.smtp.enabled .Values.smtp.auth.existingSecret }}
- name: FP_SMTP_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ tpl .Values.smtp.auth.existingSecret . }}
      key: {{ .Values.smtp.auth.usernameKey | default "username" }}
- name: FP_SMTP_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ tpl .Values.smtp.auth.existingSecret . }}
      key: {{ .Values.smtp.auth.passwordKey | default "password" }}
{{- end }}
{{- end -}}

{{/*
ServiceAccount name.
*/}}
{{- define "site.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{ default (include "common.names.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
{{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}
