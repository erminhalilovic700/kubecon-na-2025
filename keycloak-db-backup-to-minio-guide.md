# Keycloak database backup → MinIO

Goal: a **nightly backup** of the Keycloak PostgreSQL database (`keycloak-postgres` in namespace
`keycloak`) uploaded to a MinIO bucket, with old backups deleted automatically.

**How it works:**

- **When:** a Kubernetes **CronJob** runs every night at **02:00 New York time**.
- **Step 1, dump:** a `postgres:17` container runs `pg_dump` (compressed custom format) and checks
  the file is readable.
- **Step 2, upload:** an `amazon/aws-cli` container uploads the file to `s3://keycloak-backups/db/`
  on MinIO, over the cluster-internal S3 address `minio.minio.svc.cluster.local:9000`.
- **Retention:** a MinIO **lifecycle rule** deletes backups older than **30 days**.
- **Least privilege:** a dedicated MinIO user `keycloak-backup` can only write and read this one
  bucket. It **can't delete**, so a compromised backup job can't wipe your backups.

**Already checked:**

- **Size:** the database is 13 MB, and a dump is about **255 KB**, so 30 days ≈ 8 MB.
- **Manifest:** the CronJob below passes server-side validation on the cluster.
- **No `mc` client:** `minio/mc` no longer exists on Docker Hub (MinIO withdrew its images), which
  is why the upload uses the AWS CLI.

---

## Part 1: MinIO (in the console at https://content.erminstudio.com)

Log in with **Login with Keycloak** (you have `consoleAdmin`).

### 1.1 Create the bucket

**Buckets** (left menu) → **Create Bucket**:

- **Bucket Name:** `keycloak-backups`
- Leave Versioning / Object Locking / Quota off → **Create Bucket**

### 1.2 Add the 30-day cleanup rule

**Buckets** → click `keycloak-backups` → **Lifecycle** tab → **Add Lifecycle Rule**:

- **Type of lifecycle:** Expiry
- **Prefix:** `db/`
- **After:** `30` days
- → **Save**

### 1.3 Create a policy that only allows this bucket

**Policies** (left menu, under Administrator) → **Create Policy**:

- **Policy Name:** `keycloak-backup`
- Replace the editor contents with:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::keycloak-backups"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": ["arn:aws:s3:::keycloak-backups/*"]
    }
  ]
}
```

→ **Save**

### 1.4 Create the backup user

**Identity** → **Users** → **Create User**:

- **User Name (Access Key):** `keycloak-backup`
- **Password (Secret Key):** generate a strong one, at least 8 characters. On your Mac:
  `openssl rand -base64 24`. Keep it for step 2.1.
- **Assign Policies:** tick `keycloak-backup` only
- → **Save**

---

## Part 2: Kubernetes

### 2.1 Store the MinIO credentials in the `keycloak` namespace (kept out of git)

Replace `PASTE_SECRET_KEY` with the password from 1.4:

```sh
kubectl -n keycloak create secret generic keycloak-backup-s3 \
  --from-literal=AWS_ACCESS_KEY_ID=keycloak-backup \
  --from-literal=AWS_SECRET_ACCESS_KEY='PASTE_SECRET_KEY'
```

### 2.2 Add the CronJob to the repo

In `~/Projects/erminstudio` (run `git pull` first), create **`keycloak/backup-cronjob.yaml`**:

```yaml
# Nightly Keycloak database backup: pg_dump -> MinIO bucket "keycloak-backups"
apiVersion: batch/v1
kind: CronJob
metadata:
  name: keycloak-db-backup
  namespace: keycloak
spec:
  schedule: "0 2 * * *"
  timeZone: America/New_York
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 900
      template:
        spec:
          restartPolicy: Never
          volumes:
            - name: backup
              emptyDir: {}
          initContainers:
            # 1. Dump the database (custom format, compressed) and check the file is readable
            - name: pg-dump
              image: postgres:17
              env:
                - name: PGHOST
                  value: keycloak-postgres
                - name: PGDATABASE
                  value: keycloak
                - name: PGUSER
                  valueFrom:
                    secretKeyRef: {name: keycloak-db, key: username}
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef: {name: keycloak-db, key: password}
              command: ["sh", "-c"]
              args:
                - |
                  set -eu
                  f=/backup/keycloak-$(date -u +%Y%m%dT%H%M%SZ).dump
                  pg_dump --format=custom --file="$f"
                  pg_restore --list "$f" > /dev/null
                  ls -l "$f"
              volumeMounts:
                - name: backup
                  mountPath: /backup
          containers:
            # 2. Upload the dump to MinIO
            - name: upload
              image: amazon/aws-cli:2.37.11
              env:
                - name: AWS_ACCESS_KEY_ID
                  valueFrom:
                    secretKeyRef: {name: keycloak-backup-s3, key: AWS_ACCESS_KEY_ID}
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom:
                    secretKeyRef: {name: keycloak-backup-s3, key: AWS_SECRET_ACCESS_KEY}
                - name: AWS_ENDPOINT_URL
                  value: http://minio.minio.svc.cluster.local:9000
                - name: AWS_DEFAULT_REGION
                  value: us-east-1
                # Only send/verify checksums when S3 requires them (MinIO-friendly)
                - name: AWS_REQUEST_CHECKSUM_CALCULATION
                  value: when_required
                - name: AWS_RESPONSE_CHECKSUM_VALIDATION
                  value: when_required
              command: ["sh", "-c"]
              args:
                - |
                  set -eu
                  aws configure set default.s3.addressing_style path
                  aws s3 cp /backup/ s3://keycloak-backups/db/ --recursive
                  echo "Latest backups:"
                  aws s3 ls s3://keycloak-backups/db/ | tail -5
              volumeMounts:
                - name: backup
                  mountPath: /backup
```

### 2.3 Add it to `keycloak/kustomization.yaml`

Add one line at the end of `resources:`:

```yaml
resources:
  - namespace.yaml
  - https://github.com/keycloak/keycloak-k8s-resources//kubernetes?ref=26.8.0
  - postgres.yaml
  - keycloak.yaml
  - istio.yaml
  - backup-cronjob.yaml
```

### 2.4 Check, commit, push

```sh
kubectl kustomize keycloak > /dev/null && echo "YAML OK"
kubectl diff -k keycloak/        # should show only the new CronJob
git add keycloak/backup-cronjob.yaml keycloak/kustomization.yaml
git commit -m "Keycloak: nightly DB backup to MinIO"
git push origin main
```

Argo CD syncs it within a few minutes. Confirm it exists:

```sh
kubectl -n keycloak get cronjob keycloak-db-backup
```

---

## Part 3: Test it now (don't wait for 02:00)

### 3.1 Run a backup by hand

```sh
kubectl -n keycloak create job --from=cronjob/keycloak-db-backup keycloak-db-backup-test
kubectl -n keycloak wait --for=condition=complete job/keycloak-db-backup-test --timeout=180s
kubectl -n keycloak logs job/keycloak-db-backup-test -c pg-dump
kubectl -n keycloak logs job/keycloak-db-backup-test -c upload
```

The `upload` log should end with `Latest backups:` and a line like
`… 261512 keycloak-20261011T….dump`. In the MinIO console, the file appears under
**Buckets → keycloak-backups → Browse → db/**.

Clean up the test job afterwards:

```sh
kubectl -n keycloak delete job keycloak-db-backup-test
```

### 3.2 Test a restore (safe: restores into a throwaway database)

A backup you've never restored is only a hope. This restores into a **separate test database**
and leaves the real `keycloak` database untouched.

1. In the MinIO console, **download** the newest `.dump` file from `keycloak-backups/db/` to your Mac.
2. Copy it into the Postgres pod and restore it into a new database:

```sh
kubectl -n keycloak cp ~/Downloads/keycloak-XXXX.dump keycloak-postgres-0:/tmp/test.dump
kubectl -n keycloak exec keycloak-postgres-0 -- sh -c '
  createdb -U "$POSTGRES_USER" keycloak_restore_test &&
  pg_restore -U "$POSTGRES_USER" -d keycloak_restore_test --no-owner /tmp/test.dump &&
  psql -U "$POSTGRES_USER" -d keycloak_restore_test -tAc "select count(*) as realms from realm; select count(*) as users from user_entity;"'
```

You should see your realm count (2: master + erminstudio) and user count.

3. Clean up:

```sh
kubectl -n keycloak exec keycloak-postgres-0 -- sh -c 'dropdb -U "$POSTGRES_USER" keycloak_restore_test; rm -f /tmp/test.dump'
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Job pod stuck `CreateContainerConfigError` | Secret `keycloak-backup-s3` missing / wrong key names | Redo 2.1 exactly |
| `pg-dump` log: `password authentication failed` | wrong `keycloak-db` keys | `kubectl -n keycloak get secret keycloak-db -o jsonpath='{.data}'` should show `username` and `password` |
| `upload` log: `InvalidAccessKeyId` / `SignatureDoesNotMatch` | wrong access/secret key | Recreate the secret (delete + 2.1) with the user from 1.4 |
| `upload` log: `AccessDenied` | policy not attached, or a typo in the bucket name | Check 1.3/1.4 and that the bucket is exactly `keycloak-backups` |
| `upload` log: `NoSuchBucket` | bucket not created | Do 1.1 |

---

## Emergency: restoring the real database (only if Keycloak's data is lost)

Keycloak must be **stopped** while its database is replaced. Argo CD would immediately undo a
manual scale-down (self-heal), so pause it first:

1. In Argo CD, open the `keycloak` app → **App Details** → **Disable Auto-Sync**.
2. `kubectl -n keycloak patch keycloak keycloak --type merge -p '{"spec":{"instances":0}}'`
3. Copy the dump into the Postgres pod (as in 3.2), then:
   `pg_restore -U keycloak -d keycloak --clean --if-exists --no-owner /tmp/restore.dump`
4. `kubectl -n keycloak patch keycloak keycloak --type merge -p '{"spec":{"instances":1}}'`
5. Re-enable Auto-Sync in Argo CD.

Ask Claude before doing this for real. It's easy to get the order wrong under pressure.
