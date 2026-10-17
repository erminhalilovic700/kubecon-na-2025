# MinIO → RustFS migration runbook

RustFS speaks the same S3 API, but it is **not** a binary drop-in here: its MinIO on-disk
compatibility is still "Preview", the env vars are `RUSTFS_*`, and our patched MinIO console
can't talk to it. So we run RustFS next to MinIO, copy data + identities across, then flip the
`minio` Service to RustFS. Every consumer (Loki, Mimir, Tempo, Keycloak backup, `content` app)
uses `minio.minio.svc.cluster.local:9000` and keeps its current keys, so **no app changes**.

Images (mirrored to `ermin700/`): `rustfs:1.0.2`, `rclone:1.75.2`, `rc:v0.1.36`.

What gets migrated (inventoried 2026-10-16):

| Item | Detail |
|---|---|
| Buckets | `content`, `eql`, `keycloak-backups`, `loki-admin`, `loki-chunks`, `loki-ruler`, `mimir-alertmanager`, `mimir-blocks`, `mimir-ruler`, `tempo-traces` (~214 MB) |
| Bucket settings | none: no versioning, bucket policies or lifecycle rules |
| `content-app` | user, policy `content-rw` |
| `keycloak-backup` | user, policy `keycloak-backup` |
| `9C5Us37qaU1I7DxQdT9H` | service account under root (Loki/Mimir/Tempo) |

## Phase 1: run RustFS alongside MinIO

1. Merge the PR adding `minio/rustfs.yaml`. Argo CD creates `rustfs-0` + Service `rustfs`.
   ```sh
   kubectl -n minio rollout status sts/rustfs
   ```
2. Recreate the identities (same access/secret keys as today):
   ```sh
   ./minio/migrate-to-rustfs/setup-iam.sh     # ends with three "OK" lines
   ```
3. Copy and verify the data:
   ```sh
   kubectl apply -f minio/migrate-to-rustfs/rclone-sync-job.yaml
   kubectl -n minio logs -f job/rclone-sync    # ends with ALL BUCKETS SYNCED AND VERIFIED
   ```
4. Look around the RustFS console (root login):
   ```sh
   kubectl -n minio port-forward svc/rustfs 9001:9001   # http://localhost:9001/rustfs/console/
   ```

## Phase 2: cut over

1. **Keycloak (manual):** in the `minio` client add the redirect URI
   `https://content.erminstudio.com/rustfs/admin/v3/oidc/callback/default`
   (keep the old one until the cutover is confirmed).
2. Run a final delta copy right before merging, so only seconds of writes are at risk:
   ```sh
   kubectl -n minio delete job rclone-sync
   kubectl apply -f minio/migrate-to-rustfs/rclone-sync-job.yaml && kubectl -n minio logs -f job/rclone-sync
   ```
3. Merge the cutover PR. It:
   - points the `minio` Service at `app: rustfs` (consumers follow automatically),
   - adds Keycloak OIDC to RustFS (`RUSTFS_IDENTITY_OPENID_*`, roles claim `policy` →
     built-in `consoleAdmin` / `readwrite` / `readonly`, same as before),
   - routes `content.erminstudio.com` to the RustFS console on 9001,
   - removes the MinIO StatefulSet and the `minio-console` Deployment.
4. Verify: Grafana still shows logs/metrics/traces, trigger the backup
   (`kubectl -n keycloak create job --from=cronjob/keycloak-db-backup test-backup`), log in at
   https://content.erminstudio.com with Keycloak.

## Rollback

The MinIO PVC `data-minio-0` is kept (`whenDeleted: Retain`). Revert the cutover PR and Argo CD
brings MinIO back on its untouched data. Delete the PVC only once you're happy.
