#!/usr/bin/env bash
# One-off: recreate MinIO's IAM identities on RustFS with the SAME keys, so no app
# secret has to change. Run from the repo root after RustFS is up (rustfs-migration-runbook.md).
#
#   content-app           -> policy content-rw       (minio/content-app-credentials)
#   keycloak-backup       -> policy keycloak-backup  (keycloak/keycloak-backup-s3)
#   9C5Us37qaU1I7DxQdT9H  -> service account under root, inherits root (observability/minio-creds)
#
# Secrets are read with kubectl and streamed to the pod over stdin, never passed as arguments.
set -euo pipefail

NS=minio
POD=rustfs-iam-setup
IMAGE=ermin700/rc:v0.1.36   # mirror of rustfs/rc:v0.1.36
ENDPOINT=http://rustfs.minio.svc.cluster.local:9000

secret() { kubectl get secret -n "$1" "$2" -o jsonpath="{.data.$3}" | base64 -d; }

ROOT_USER=$(secret minio minio-credentials rootUser)
ROOT_PASS=$(secret minio minio-credentials rootPassword)
CONTENT_KEY=$(secret minio content-app-credentials AWS_ACCESS_KEY_ID)
CONTENT_SECRET=$(secret minio content-app-credentials AWS_SECRET_ACCESS_KEY)
BACKUP_KEY=$(secret keycloak keycloak-backup-s3 AWS_ACCESS_KEY_ID)
BACKUP_SECRET=$(secret keycloak keycloak-backup-s3 AWS_SECRET_ACCESS_KEY)
OBS_KEY=$(secret observability minio-creds MINIO_ACCESS_KEY)
OBS_SECRET=$(secret observability minio-creds MINIO_SECRET_KEY)

cleanup() { kubectl delete pod -n "$NS" "$POD" --ignore-not-found --wait=false >/dev/null; }
trap cleanup EXIT

kubectl run -n "$NS" "$POD" --image="$IMAGE" --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsUser":65534,"runAsGroup":65534,"runAsNonRoot":true}}}' \
  --env=HOME=/tmp --command -- sleep 600 >/dev/null
kubectl wait -n "$NS" --for=condition=Ready "pod/$POD" --timeout=120s >/dev/null

# Quoted heredoc pieces are literal; only the KEY=value header is expanded locally.
{
  printf "ROOT_USER='%s' ROOT_PASS='%s'\n" "$ROOT_USER" "$ROOT_PASS"
  printf "CONTENT_KEY='%s' CONTENT_SECRET='%s'\n" "$CONTENT_KEY" "$CONTENT_SECRET"
  printf "BACKUP_KEY='%s' BACKUP_SECRET='%s'\n" "$BACKUP_KEY" "$BACKUP_SECRET"
  printf "OBS_KEY='%s' OBS_SECRET='%s'\n" "$OBS_KEY" "$OBS_SECRET"
  printf "ENDPOINT='%s'\n" "$ENDPOINT"
  cat <<'EOF'
set -e
cd /tmp
rc alias set r "$ENDPOINT" "$ROOT_USER" "$ROOT_PASS" -q --bucket-lookup path

cat > content-rw.json <<'JSON'
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:GetBucketLocation","s3:ListBucket","s3:ListBucketMultipartUploads"],"Resource":["arn:aws:s3:::content"]},
 {"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::content/*"]}]}
JSON
cat > keycloak-backup.json <<'JSON'
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:GetBucketLocation","s3:ListBucket"],"Resource":["arn:aws:s3:::keycloak-backups"]},
 {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject"],"Resource":["arn:aws:s3:::keycloak-backups/*"]}]}
JSON

# Idempotent: skip anything that already exists, so the script is safe to re-run.
for p in content-rw keycloak-backup; do
  rc admin policy info r "$p" >/dev/null 2>&1 || rc admin policy create r "$p" "$p.json"
done

rc admin user info r "$CONTENT_KEY" >/dev/null 2>&1 || {
  rc admin user add r "$CONTENT_KEY" "$CONTENT_SECRET"
  rc admin policy attach r content-rw --user "$CONTENT_KEY"; }
rc admin user info r "$BACKUP_KEY" >/dev/null 2>&1 || {
  rc admin user add r "$BACKUP_KEY" "$BACKUP_SECRET"
  rc admin policy attach r keycloak-backup --user "$BACKUP_KEY"; }

rc admin service-account info r "$OBS_KEY" >/dev/null 2>&1 \
  || rc admin service-account create r "$OBS_KEY" "$OBS_SECRET" --name observability \
       --description "Loki, Mimir, Tempo" | grep -v '^Secret Key'

echo "== check: each identity can list its bucket"
rc alias set c "$ENDPOINT" "$CONTENT_KEY" "$CONTENT_SECRET" -q --bucket-lookup path
rc alias set k "$ENDPOINT" "$BACKUP_KEY" "$BACKUP_SECRET" -q --bucket-lookup path
rc alias set o "$ENDPOINT" "$OBS_KEY" "$OBS_SECRET" -q --bucket-lookup path
rc object list c/content >/dev/null && echo "content-app      OK"
rc object list k/keycloak-backups >/dev/null && echo "keycloak-backup  OK"
rc object list o/loki-chunks >/dev/null && echo "observability    OK"
EOF
} | kubectl exec -i -n "$NS" "$POD" -- sh -s

echo "IAM setup done."
