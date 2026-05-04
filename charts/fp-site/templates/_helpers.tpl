{{/*
fp-site helpers.

Most naming and labeling work goes through `bitnami/common`'s helpers
(`common.names.fullname`, `common.labels.standard`, `common.images.image`,
`common.tplvalues.render`, etc.). The wrappers below resolve names of
peer resources (DB, cache, S3) so subchart-vs-external can be one
template change.
*/}}

{{/*
Image reference. Honors the `image.digest` precedence over `image.tag`.
*/}}
{{- define "fp-site.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global "chart" .Chart) }}
{{- end -}}

{{/*
Name of the keys+salts Secret. Auto-generated default, or an existing one.
*/}}
{{- define "fp-site.secretName" -}}
{{- if .Values.keysSalts.existingSecret -}}
{{ tpl .Values.keysSalts.existingSecret . }}
{{- else -}}
{{ printf "%s-keys" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{- end -}}

{{/*
Database host. When the in-chart MariaDB subchart is enabled, the
`<release>-mariadb` service is the canonical Service name for bitnami/mariadb.
*/}}
{{- define "fp-site.databaseHost" -}}
{{- if .Values.mariadb.enabled -}}
{{ printf "%s-mariadb" (include "common.names.fullname" .) }}
{{- else -}}
{{ .Values.externalDatabase.host }}
{{- end -}}
{{- end -}}

{{- define "fp-site.databasePort" -}}
{{- if .Values.mariadb.enabled -}}3306{{- else -}}{{ .Values.externalDatabase.port }}{{- end -}}
{{- end -}}

{{- define "fp-site.databaseName" -}}
{{- if .Values.mariadb.enabled -}}{{ .Values.mariadb.auth.database }}{{- else -}}{{ .Values.externalDatabase.database }}{{- end -}}
{{- end -}}

{{- define "fp-site.databaseUser" -}}
{{- if .Values.mariadb.enabled -}}{{ .Values.mariadb.auth.username }}{{- else -}}{{ .Values.externalDatabase.user }}{{- end -}}
{{- end -}}

{{/*
Name of the Secret holding the DB password (subchart-managed or external).
*/}}
{{- define "fp-site.databaseSecretName" -}}
{{- if .Values.mariadb.enabled -}}
{{ printf "%s-mariadb" (include "common.names.fullname" .) }}
{{- else if .Values.externalDatabase.existingSecret -}}
{{ tpl .Values.externalDatabase.existingSecret . }}
{{- else -}}
{{ printf "%s-db" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{- end -}}

{{- define "fp-site.databaseSecretPasswordKey" -}}
{{- if .Values.mariadb.enabled -}}
mariadb-password
{{- else -}}
{{ .Values.externalDatabase.existingSecretPasswordKey | default "password" }}
{{- end -}}
{{- end -}}

{{/*
Cache (Redis-compatible) host.
*/}}
{{- define "fp-site.cacheHost" -}}
{{- if .Values.redis.enabled -}}
{{ printf "%s-redis-master" (include "common.names.fullname" .) }}
{{- else -}}
{{ .Values.externalCache.host }}
{{- end -}}
{{- end -}}

{{- define "fp-site.cachePort" -}}
{{- if .Values.redis.enabled -}}6379{{- else -}}{{ .Values.externalCache.port }}{{- end -}}
{{- end -}}

{{- define "fp-site.cacheUrl" -}}
{{- printf "%s:%s" (include "fp-site.cacheHost" .) (include "fp-site.cachePort" .) -}}
{{- end -}}

{{/*
S3 endpoint host. For in-chart MinIO, point at the subchart's Service.
*/}}
{{- define "fp-site.s3Endpoint" -}}
{{- if .Values.minio.enabled -}}
{{ printf "http://%s-minio:9000" (include "common.names.fullname" .) }}
{{- else -}}
{{ .Values.externalS3.endpoint }}
{{- end -}}
{{- end -}}

{{- define "fp-site.s3Bucket" -}}
{{- if .Values.minio.enabled -}}
{{ .Values.minio.defaultBuckets | default "site-media" }}
{{- else -}}
{{ .Values.externalS3.bucket }}
{{- end -}}
{{- end -}}

{{- define "fp-site.s3Region" -}}
{{- if .Values.minio.enabled -}}us-east-1{{- else -}}{{ .Values.externalS3.region }}{{- end -}}
{{- end -}}

{{/*
Name of the Secret holding S3 access keys.
*/}}
{{- define "fp-site.s3SecretName" -}}
{{- if .Values.minio.enabled -}}
{{ printf "%s-minio" (include "common.names.fullname" .) }}
{{- else if .Values.externalS3.existingSecret -}}
{{ tpl .Values.externalS3.existingSecret . }}
{{- else -}}
{{ printf "%s-s3" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{- end -}}

{{- define "fp-site.s3AccessKeyKey" -}}
{{- if .Values.minio.enabled -}}root-user{{- else -}}access-key{{- end -}}
{{- end -}}

{{- define "fp-site.s3SecretKeyKey" -}}
{{- if .Values.minio.enabled -}}root-password{{- else -}}secret-key{{- end -}}
{{- end -}}

{{/*
ServiceAccount name.
*/}}
{{- define "fp-site.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{ default (include "common.names.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
{{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}
