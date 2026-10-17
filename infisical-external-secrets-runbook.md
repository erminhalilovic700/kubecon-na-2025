# Runbook: move cluster secrets into Infisical with External Secrets Operator

**Goal:** Infisical becomes the **single source of truth** for your app secrets. External Secrets
Operator (ESO), deployed by Argo CD, keeps normal Kubernetes Secrets in sync with Infisical, so
**your apps don't change at all**. They keep reading the same Secret names and keys.

```
Infisical  (project erminstudio, env prod, folder /<namespace>/<secret>)
    │  ClusterSecretStore "infisical" (in-cluster: http://infisical.infisical.svc:8080)
    ▼
External Secrets Operator ──► Kubernetes Secret <secret> in <namespace> ──► app (unchanged)
```

## What's in this folder on your Desktop

| File | Purpose |
|---|---|
| `infisical-external-secrets-runbook.md` | this runbook |
| `infisical-migrate-secrets.py` | **the copy script**: Kubernetes Secrets → Infisical, values never printed |
| `infisical-eso-files/` | ready-made repo files (copy into `erminstudio` in Part 4) |

**Already checked:**

- **Script:** a dry run read all **9 secrets / 18 keys**, and its port-forward and login call reached
  your Infisical (fake credentials were correctly rejected). The write calls first run for real in
  Part 3, and the script then verifies every secret.
- **ESO fields:** every field used was checked against the ESO **2.12.0** CRD schemas.
- **Argo app:** the Argo CD Application passed a server-side dry run.

## What moves to Infisical, and what stays

| Moves (9 Secrets, 18 keys) | Used by |
|---|---|
| `keycloak/keycloak-db` | Keycloak, PostgreSQL 18, backup CronJob |
| `keycloak/keycloak-backup-s3` | backup CronJob |
| `observability/grafana-admin`, `observability/grafana-oauth` | Grafana |
| `observability/minio-creds` | Loki, Mimir, Tempo |
| `minio/minio-credentials`, `minio/minio-console-secret`, `minio/minio-oidc` | MinIO server and console |
| `minio/content-app-credentials` | apps using the `content` bucket |

| Stays as a plain Kubernetes Secret | Why |
|---|---|
| `infisical/*` (`infisical-secrets`, `-postgres`, `-redis`) | Infisical can't store the keys it needs to start (chicken and egg) |
| `external-secrets/infisical-universal-auth` | the key ESO uses to log in to Infisical |
| `argocd/*` | managed by the Argo CD install itself. Argo CD must work even if Infisical is down |
| `keycloak/keycloak-initial-admin` | created by the Keycloak operator; goes away with `temp-admin` |
| `default/certificate`, `observability/certificate` | **no pod uses them**. Probably leftovers; check and delete later |

> **Do you need Reflector?** No. Reflector copies one Secret into many namespaces. With a
> **ClusterSecretStore**, every namespace pulls directly from Infisical.
> **Reloader** (stakater) is a different tool, and optional: it restarts pods when a Secret's
> value changes. See Part 8.

## How the switch stays safe

ESO **takes over an existing Secret and replaces its data** with what's in Infisical. A wrong or
missing value would break the app using it. So this runbook:

1. backs up every Secret first (Part 1),
2. lets the script verify Infisical matches Kubernetes (Part 3),
3. has ESO write to **test copies** (`<name>-infisical-check`) first and compares them (Part 5),
4. and only then points ESO at the real Secrets (Part 6), with `creationPolicy: Orphan`, so the
   Secrets stay even if ESO or the ExternalSecrets are ever removed.

---

## Part 1: Back up the current Secrets

```sh
B=~/secret-backup-$(date +%Y%m%d); mkdir -m 700 "$B"
for ref in keycloak/keycloak-db keycloak/keycloak-backup-s3 observability/grafana-admin \
           observability/grafana-oauth observability/minio-creds minio/minio-credentials \
           minio/minio-console-secret minio/minio-oidc minio/content-app-credentials; do
  kubectl -n "${ref%/*}" get secret "${ref#*/}" -o yaml > "$B/${ref%/*}__${ref#*/}.yaml"
done
ls "$B"     # 9 files
```

> These files contain your secrets (base64 only, not encrypted). They're for rollback only.
> **Delete the folder in Part 7.**

To restore one if something breaks: `kubectl apply -f "$B/<namespace>__<secret>.yaml"`.

---

## Part 2: Infisical setup (web UI)

Log in at **https://infisical.erminstudio.com**, organization → project **erminstudio**.

### 2.1 Check the Production environment

In the project, the environment dropdown (top left of the secrets table) should include
**Production**. **Project Settings → Environments** should show its slug as **`prod`**.

### 2.2 Create two machine identities

**Organization → Access Control → Identities** (or **Machine Identities**) → **Create Identity**:

| Name | Organization role | Purpose |
|---|---|---|
| `external-secrets` | No Access | ESO reads secrets (permanent) |
| `infisical-migration` | No Access | the copy script writes secrets (**temporary**, deleted in Part 7) |

For **each** identity: open it → **Universal Auth** (the default method) → **Client Secrets** →
**Create Client Secret** (any description, no expiry for `external-secrets`) → copy the **Client
ID** and the **Client Secret** immediately (the secret is shown once).

### 2.3 Give them access to the project

Project **erminstudio** → **Access Control** → **Machine Identities** → **Add Identity**:

| Identity | Project role |
|---|---|
| `external-secrets` | **Viewer** (read only) |
| `infisical-migration` | **Admin** (needs to create folders and secrets) |

---

## Part 3: Copy the secrets into Infisical (the script)

```sh
cd ~/Desktop
python3 infisical-migrate-secrets.py --dry-run     # lists 9 secrets / 18 keys, sends nothing
python3 infisical-migrate-secrets.py               # asks for the infisical-migration Client ID + Secret
```

The secret prompt is hidden, so nothing lands in your shell history. The script:

- port-forwards to `svc/infisical` itself (Cloudflare Access isn't involved),
- creates `/keycloak/keycloak-db`, `/minio/minio-oidc`, … in environment **prod**,
- writes every key (re-running is safe, it updates instead of duplicating),
- **reads everything back and compares** (fingerprints only), printing `OK` per Secret,
- prints your **project slug** at the end. **Note it down**, you need it in Part 4.

Expected end: `All secrets match.` In the Infisical UI (environment **Production**) you'll now see
the folders `keycloak`, `minio`, `observability`.

Re-check any time without changing anything: `python3 infisical-migrate-secrets.py --verify`.

---

## Part 4: Install ESO with Argo CD

### 4.1 Store the `external-secrets` identity's credentials (by hand, not in git)

```sh
kubectl create namespace external-secrets
kubectl -n external-secrets create secret generic infisical-universal-auth \
  --from-literal=clientId='PASTE_EXTERNAL_SECRETS_CLIENT_ID' \
  --from-literal=clientSecret='PASTE_EXTERNAL_SECRETS_CLIENT_SECRET'
```

Use the **`external-secrets`** identity here, not the migration one.

### 4.2 Copy the ready-made files into the repo

```sh
cd ~/Projects/erminstudio && git pull
cp -R ~/Desktop/infisical-eso-files/argo ~/Desktop/infisical-eso-files/external-secrets .
```

This adds:

```
argo/external-secrets-app.yaml                    # Argo CD app: ESO chart 2.12.0 + the manifests below
external-secrets/manifests/infisical-store.yaml   # ClusterSecretStore "infisical"
external-secrets/manifests/externalsecrets.yaml   # 9 ExternalSecrets, writing to *-infisical-check (test mode)
```

### 4.3 Put your project slug in the store

Open `external-secrets/manifests/infisical-store.yaml` and replace `PROJECT_SLUG` with the slug the
script printed. **Save the file**, then check:

```sh
grep projectSlug external-secrets/manifests/infisical-store.yaml     # must NOT say PROJECT_SLUG
```

### 4.4 Commit, push, register

```sh
git add argo/external-secrets-app.yaml external-secrets/
git status                     # expect exactly 3 new files staged
git commit -m "Add External Secrets Operator with Infisical store (test mode)"
git push origin main
kubectl apply -f argo/external-secrets-app.yaml
```

> **Check the commit output says "3 files changed".** A missing file was the cause of most
> problems last time.

### 4.5 Check ESO and the store

```sh
kubectl -n external-secrets get pods -w              # 3 pods Running (controller, webhook, cert-controller), then Ctrl+C
kubectl -n argocd get application external-secrets  # Synced  Healthy (may take 2–3 min)
kubectl get clustersecretstore infisical              # STATUS Valid, READY True
```

If the store isn't `Valid`: `kubectl describe clustersecretstore infisical`, then look at the
**Troubleshooting** table below.

---

## Part 5: Test run, ESO writes copies and you compare them

The ExternalSecrets currently write to **`<name>-infisical-check`**, so your real Secrets are
untouched. Compare each copy with its original:

```sh
kubectl get externalsecrets -A        # all 9: STATUS SecretSynced, READY True

for ref in keycloak/keycloak-db keycloak/keycloak-backup-s3 observability/grafana-admin \
           observability/grafana-oauth observability/minio-creds minio/minio-credentials \
           minio/minio-console-secret minio/minio-oidc minio/content-app-credentials; do
  ns=${ref%/*}; s=${ref#*/}
  t='{{range $k,$v := .data}}{{$k}}={{$v}};{{end}}'
  a=$(kubectl -n $ns get secret $s -o go-template="$t" | shasum -a 256)
  b=$(kubectl -n $ns get secret $s-infisical-check -o go-template="$t" 2>/dev/null | shasum -a 256)
  [ "$a" = "$b" ] && echo "OK    $ref" || echo "DIFF  $ref"
done
```

**All 9 must say `OK`.** Any `DIFF` means Infisical's copy differs from the live Secret. Don't
continue; ask Claude, or compare key names with
`kubectl -n <ns> get secret <name>-infisical-check -o jsonpath='{.data}' | tr ',' '\n' | cut -d'"' -f2`.

---

## Part 6: Switch ESO to the real Secrets

One command changes all 9 ExternalSecrets: the target becomes the real Secret name, and the
creation policy becomes **Orphan**:

```sh
cd ~/Projects/erminstudio
sed -i '' -e 's/-infisical-check$//' -e 's/creationPolicy: Owner/creationPolicy: Orphan/' \
  external-secrets/manifests/externalsecrets.yaml
git diff --stat                     # 1 file, 18 lines changed (9 names + 9 policies)
grep -c 'infisical-check' external-secrets/manifests/externalsecrets.yaml   # must print 0
git add external-secrets/manifests/externalsecrets.yaml
git commit -m "External Secrets: manage the real Secrets from Infisical"
git push origin main
kubectl -n argocd annotate application external-secrets argocd.argoproj.io/refresh=hard --overwrite
```

Verify ESO now manages the real Secrets, with the **same content as your backup**:

```sh
kubectl get externalsecrets -A      # all 9 SecretSynced / True

for f in "$B"/*.yaml; do
  ns=$(basename "$f" .yaml); s=${ns#*__}; ns=${ns%%__*}
  t='{{range $k,$v := .data}}{{$k}}={{$v}};{{end}}'
  a=$(kubectl -n $ns get secret $s -o go-template="$t" | shasum -a 256)
  b=$(kubectl create --dry-run=client -o go-template="$t" -f "$f" | shasum -a 256)
  [ "$a" = "$b" ] && echo "OK    $ns/$s unchanged" || echo "DIFF  $ns/$s"
done
```

(`$B` is your backup folder from Part 1. If you opened a new terminal: `B=~/secret-backup-YYYYMMDD`.)

Then check the apps still work:

- https://keycloak.erminstudio.com/admin, and SSO into Grafana, Argo CD and MinIO
- `kubectl -n observability get pods`: Loki/Mimir/Tempo all Running
- `kubectl -n keycloak create job --from=cronjob/keycloak-db-backup eso-test && kubectl -n keycloak wait --for=condition=complete job/eso-test --timeout=180s && kubectl -n keycloak delete job eso-test`

---

## Part 7: Clean up

```sh
# the 9 test copies from Part 5
for ref in keycloak/keycloak-db keycloak/keycloak-backup-s3 observability/grafana-admin \
           observability/grafana-oauth observability/minio-creds minio/minio-credentials \
           minio/minio-console-secret minio/minio-oidc minio/content-app-credentials; do
  kubectl -n "${ref%/*}" delete secret "${ref#*/}-infisical-check" --ignore-not-found
done

# the local backup (contains secrets)
rm -rf ~/secret-backup-*
```

In Infisical: **Organization → Access Control → Identities** → delete **`infisical-migration`**.
Only `external-secrets` (read-only) should remain.

---

## Part 8: Day-to-day

- **Change a secret:** edit it in Infisical (Production → folder). ESO updates the Kubernetes Secret
  within **1 hour** (`refreshInterval`). To apply it immediately:
  ```sh
  kubectl -n <namespace> annotate externalsecret <name> force-sync=$(date +%s) --overwrite
  ```
  Pods read Secrets at start-up, so **restart the app** afterwards
  (`kubectl -n <ns> rollout restart deploy/<name>` or `statefulset/<name>`). Reloader would automate this.
- **Rotating a password** (e.g. a database): change it in the database **and** in Infisical, then
  force-sync and restart. Infisical only stores the value; it doesn't change it in the app.
- **New app secret:** create folder `/<namespace>/<secret>` in Infisical, add a matching
  ExternalSecret to `external-secrets/manifests/externalsecrets.yaml` (copy an existing one;
  target name = Secret name, `creationPolicy: Orphan`), commit and push.
- **Back up the Infisical database.** It's now where all these secrets live. Copy the Keycloak
  backup CronJob for `infisical-postgres`, and keep the `ENCRYPTION_KEY` in your password manager.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Script: `Login failed (HTTP 401)` | wrong Client ID/Secret, or the secret expired | create a new client secret for `infisical-migration` |
| Script: `Creating folder … failed (HTTP 403)` | identity lacks project access | Part 2.3: `infisical-migration` needs project role **Admin** |
| Script: `DIFF` for a secret | value changed in Infisical, or trimmed whitespace | re-run the script, then `--verify` |
| Argo app `external-secrets` sync error about annotation size | `ServerSideApply=true` missing | it's in the ready-made app file; `kubectl apply -f argo/external-secrets-app.yaml` again |
| ClusterSecretStore not `Valid` | wrong project slug or credentials | check `projectSlug`, and the `infisical-universal-auth` Secret (Part 4.1) |
| ExternalSecret `SecretSyncedError` | folder missing in Infisical, or identity not **Viewer** on the project | `kubectl -n <ns> describe externalsecret <name>` |
| App broken after Part 6 | a Secret's content changed | `kubectl apply -f "$B/<ns>__<secret>.yaml"` to restore it, then ask Claude |

Ask Claude to verify after **Part 3**, **Part 4.5**, **Part 5** and **Part 6**.
