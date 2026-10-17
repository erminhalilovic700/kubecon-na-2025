# Upgrade Keycloak's database: PostgreSQL 17 → 18

**Already checked:**

- **Keycloak supports it:** Keycloak 26.8 supports PostgreSQL 18.x, which is the version Keycloak
  itself tests against.
- **Current database:** `keycloak-postgres` runs **PostgreSQL 17.11** (13 MB; 2 realms, 3 users,
  17 clients).
- **The 18 image changed layout:** in the official `postgres:18` image, data moved to
  `/var/lib/postgresql/18/docker`, with the volume at `/var/lib/postgresql`. 17 used
  `/var/lib/postgresql/data`. So you **can't just change `image: postgres:17` to `postgres:18`**.
  Postgres also can't open data files from an older major version without a migration.

## The approach: new database next to the old one

Instead of upgrading in place, you **create a second database on 18**, copy the data into it, and
switch Keycloak over. The old 17 database stays untouched, so **rolling back is a one-line change**.

```
  keycloak-postgres   (17)  ──pg_dump──►  your Mac  ──pg_restore──►  keycloak-postgres18  (18)
         ▲ Keycloak today                                                    ▲ Keycloak after step 7
```

**Downtime:** Keycloak is stopped for about **5 minutes** (steps 3–8). During that time nobody can
log in through Keycloak, but people already logged in to Grafana, Argo CD or MinIO stay logged in.

Work in `~/Projects/erminstudio` and run `git pull` first.

---

## Step 1: Add the new PostgreSQL 18 database (no downtime)

Create **`keycloak/postgres18.yaml`**:

```yaml
# PostgreSQL 18 for Keycloak. Uses the same "keycloak-db" Secret as the 17 instance.
# postgres:18 keeps its data under /var/lib/postgresql/18/docker (the image default),
# so the volume is mounted at /var/lib/postgresql and PGDATA is not set.
apiVersion: v1
kind: Service
metadata:
  name: keycloak-postgres18
  labels:
    app: keycloak-postgres18
spec:
  selector:
    app: keycloak-postgres18
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: keycloak-postgres18
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  serviceName: keycloak-postgres18
  replicas: 1
  selector:
    matchLabels:
      app: keycloak-postgres18
  template:
    metadata:
      labels:
        app: keycloak-postgres18
    spec:
      containers:
        - name: postgres
          image: postgres:18
          ports:
            - name: postgres
              containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: keycloak
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: keycloak-db
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-db
                  key: password
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d keycloak"]
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 5Gi
```

Add it to **`keycloak/kustomization.yaml`** under `resources:` (keep `postgres.yaml` for now):

```yaml
  - postgres.yaml
  - postgres18.yaml
```

Check, commit, push:

```sh
kubectl kustomize keycloak > /dev/null && echo "YAML OK"
kubectl diff -k keycloak/            # should show only the new Service + StatefulSet
git add keycloak/postgres18.yaml keycloak/kustomization.yaml
git commit -m "Keycloak: add PostgreSQL 18 instance (not used yet)"
git push origin main
```

Wait until it's running, then confirm the version:

```sh
kubectl -n keycloak get pods -l app=keycloak-postgres18 -w        # wait for 1/1 Running, then Ctrl+C
kubectl -n keycloak exec keycloak-postgres18-0 -- psql -U keycloak -d keycloak -tAc 'select version();'
```

You should see `PostgreSQL 18.x`. Keycloak is still on 17 at this point. Nothing has changed for users.

---

## Step 2: Pause Argo CD auto-sync for the `keycloak` app

Argo CD would immediately undo the manual scale-down in step 3 (self-heal), so pause it:

```sh
kubectl -n argocd patch application keycloak --type json \
  -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
```

---

## Step 3: Stop Keycloak (downtime starts)

```sh
kubectl -n keycloak patch keycloak keycloak --type merge -p '{"spec":{"instances":0}}'
kubectl -n keycloak get pods -w        # wait until keycloak-0 is gone, then Ctrl+C
```

With Keycloak stopped, nothing writes to the database, so the copy will be complete.

---

## Step 4: Dump the 17 database to your Mac

```sh
kubectl -n keycloak exec keycloak-postgres-0 -- \
  pg_dump -U keycloak -d keycloak --format=custom > ~/Desktop/keycloak-pg17-final.dump
ls -lh ~/Desktop/keycloak-pg17-final.dump          # expect roughly 250 KB
```

Keep this file. It's also your safety backup.

---

## Step 5: Restore it into the 18 database

```sh
kubectl -n keycloak exec -i keycloak-postgres18-0 -- \
  pg_restore -U keycloak -d keycloak --no-owner --exit-on-error < ~/Desktop/keycloak-pg17-final.dump \
  && echo "RESTORE OK"
```

---

## Step 6: Check both databases have the same data

```sh
Q="select 'realms='||count(*) from realm union all select 'users='||count(*) from user_entity union all select 'clients='||count(*) from client;"
echo "== 17:"; kubectl -n keycloak exec keycloak-postgres-0   -- psql -U keycloak -d keycloak -tAc "$Q"
echo "== 18:"; kubectl -n keycloak exec keycloak-postgres18-0 -- psql -U keycloak -d keycloak -tAc "$Q"
```

The numbers must match (currently `realms=2`, `users=3`, `clients=17`). **If they don't match,
stop here** and go to **Rollback**. Keycloak is still configured for 17.

---

## Step 7: Point Keycloak at the 18 database

In **`keycloak/keycloak.yaml`**, change one line under `db:`:

```yaml
  db:
    vendor: postgres
    host: keycloak-postgres18        # was: keycloak-postgres
```

**If you've already set up the backup CronJob** from the backup guide, also change two lines in
**`keycloak/backup-cronjob.yaml`** (`pg-dump` container):

- `image: postgres:17` → `image: postgres:18`. `pg_dump` from 17 refuses to back up an 18
  server, so nightly backups would fail without this.
- `PGHOST` value `keycloak-postgres` → `keycloak-postgres18`. Otherwise it keeps backing up the
  old, now-unused database.

Commit and push:

```sh
kubectl diff -k keycloak/      # host change (+ backup image if present)
git add keycloak/
git commit -m "Keycloak: switch database to PostgreSQL 18"
git push origin main
```

---

## Step 8: Resume Argo CD (Keycloak starts on 18, downtime ends)

Re-applying the app definition turns auto-sync back on. Argo then applies git, including the new DB
host and `instances: 1`, so Keycloak starts again:

```sh
kubectl apply -f argo/keycloak-app.yaml
kubectl -n argocd annotate application keycloak argocd.argoproj.io/refresh=hard --overwrite
kubectl -n keycloak get pods -w       # wait for keycloak-0 1/1 Running (1–2 min), then Ctrl+C
```

---

## Step 9: Verify

```sh
kubectl -n keycloak get keycloak keycloak -o jsonpath='{.spec.db.host} ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'
# expect: keycloak-postgres18 ready=True
kubectl -n keycloak logs keycloak-0 | grep -iE 'error|exception' | tail -5     # expect nothing important
```

Then in an **incognito window**:

1. https://keycloak.erminstudio.com/admin: the admin console works; realms, clients and users are all there.
2. https://grafana.erminstudio.com → **Sign in with Keycloak** works.
3. https://deploy.erminstudio.com → **Log in via Keycloak** works.
4. https://content.erminstudio.com → **Login with Keycloak** works.

---

## Rollback (if anything goes wrong)

The 17 database hasn't been touched since step 3:

1. In `keycloak/keycloak.yaml` set `host: keycloak-postgres` back (and the backup CronJob's image
   and `PGHOST` back to `postgres:17` / `keycloak-postgres` if you changed them), then commit and push.
2. If auto-sync is still paused, run step 8's commands.

Keycloak comes back on 17 exactly as it was before step 3. Anything changed in Keycloak *after*
step 8 (new users, etc.) would exist only in the 18 database.

---

## Step 10: Cleanup (after about a week of everything working)

1. Remove the old 17 database from git: delete `keycloak/postgres.yaml` and its line in
   `keycloak/kustomization.yaml`, then commit and push. Argo removes the old Service and StatefulSet.
2. The old **data volume is not removed automatically** (it came from the StatefulSet's
   `volumeClaimTemplates`). Delete it by hand. This permanently deletes the 17 data:
   ```sh
   kubectl -n keycloak delete pvc data-keycloak-postgres-0
   ```
3. Keep `~/Desktop/keycloak-pg17-final.dump` somewhere safe, or delete it once your nightly backups
   are running on 18.

Ask Claude to check things after steps 1, 6 and 9, or any time something looks off.
