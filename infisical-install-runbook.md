# Runbook: Infisical on RKE2, managed by Argo CD, exposed via Cloudflare + Istio, with Keycloak

**Result:** Infisical at **https://infisical.erminstudio.com**, deployed by Argo CD from
`kubecon-na-2025`, reached through the Cloudflare tunnel and Istio, with Keycloak in front for login.

```
browser → Cloudflare (TLS) → tunnel "RancherAPI" → http://10.0.0.100:30133 (istio-ingressgateway)
        → infisical-gateway / VirtualService → Service "infisical" :8080 → Infisical
                                                   ├─ infisical-postgres (PostgreSQL 18)
                                                   └─ infisical-redis    (Redis 7.4)
```

### Decisions and checks behind this runbook

| Topic | Decision | Why |
|---|---|---|
| Helm chart | `infisical-standalone` **1.11.0** (Infisical **v0.166.3**) | Latest chart; the chart's default image (v0.158.0) is older, so the tag is overridden |
| Ingress | chart's ingress **and its bundled nginx controller disabled**; **Istio** Gateway + VirtualService instead | Same pattern as Grafana, MinIO and Keycloak |
| Database | **Official `postgres:18`**, not the chart's Bitnami one | The chart bundles `bitnamilegacy` images (frozen, no security fixes) with hard-coded passwords (`root`). Infisical supports PostgreSQL 14+ (vendor-tested on 16) |
| Redis | **Official `redis:7.4`**, AOF persistence, `noeviction` | Infisical requires Redis **6.x/7.x**, persistent, `noeviction` (it holds job queues). Redis 8 isn't listed as supported |
| Secrets | all config in Secret `infisical-secrets`, **created by hand, never in git** | Same as Keycloak and Grafana |
| Argo CD quirk | `ignoreDifferences` on the Deployment's `updatedAt` annotation | The chart writes `updatedAt: {{ now }}` on every render. Without this, Argo CD would see a change on every refresh and restart Infisical every few minutes |
| Keycloak | see **Part 6**: Infisical's own Keycloak SSO is a **paid feature** for self-hosted | Per Infisical docs: *"Keycloak OIDC SSO is a paid feature … self-hosting … purchase a self-hosted license"* |

All manifests below passed a server-side dry run against the cluster.

---

## Part 1: Create the secrets (by hand, not in git)

Run once in your terminal. It generates random passwords and keys and stores them in three Secrets.
Hex passwords are used so they're safe inside connection URLs.

```sh
kubectl create namespace infisical

PG_PASS=$(openssl rand -hex 24)
REDIS_PASS=$(openssl rand -hex 24)

kubectl -n infisical create secret generic infisical-postgres \
  --from-literal=username=infisical \
  --from-literal=password="$PG_PASS"

kubectl -n infisical create secret generic infisical-redis \
  --from-literal=password="$REDIS_PASS"

kubectl -n infisical create secret generic infisical-secrets \
  --from-literal=ENCRYPTION_KEY="$(openssl rand -hex 16)" \
  --from-literal=AUTH_SECRET="$(openssl rand -base64 32)" \
  --from-literal=SITE_URL=https://infisical.erminstudio.com \
  --from-literal=DB_CONNECTION_URI="postgresql://infisical:${PG_PASS}@infisical-postgres:5432/infisical" \
  --from-literal=REDIS_URL="redis://:${REDIS_PASS}@infisical-redis:6379" \
  --from-literal=TELEMETRY_ENABLED=false

unset PG_PASS REDIS_PASS
kubectl -n infisical get secrets
```

### ⚠️ Save the ENCRYPTION_KEY in your password manager now

Every secret Infisical stores is encrypted with `ENCRYPTION_KEY`. **If this Kubernetes Secret is
lost, the database is unreadable and every secret in Infisical is gone**, even with a database
backup. Copy it somewhere safe outside the cluster:

```sh
kubectl -n infisical get secret infisical-secrets -o jsonpath='{.data.ENCRYPTION_KEY}' | base64 -d; echo
```

---

## Part 2: Add the files to the repo

In `~/Projects/kubecon-na-2025` (run `git pull` first), create this layout:

```
infisical/
├── values.yaml              # Helm values for the Infisical chart
└── manifests/
    ├── postgres.yaml        # PostgreSQL 18
    ├── redis.yaml           # Redis 7.4
    └── istio.yaml           # Gateway + VirtualService
argo/
└── infisical-app.yaml       # Argo CD Application
```

> Don't put these under `demo-cluster/`. The ApplicationSet there turns every file into its own app.

### 2.1 `infisical/values.yaml`

```yaml
# Helm values for the infisical-standalone chart (Argo CD app: argo/infisical-app.yaml).
# The chart's bundled ingress-nginx, Bitnami PostgreSQL and Bitnami Redis are disabled;
# PostgreSQL 18, Redis 7.4 and the Istio routing live in infisical/manifests/.
# All configuration (DB/Redis URLs, ENCRYPTION_KEY, AUTH_SECRET, SITE_URL) comes from the
# Secret "infisical-secrets", which is created by hand and never committed.
infisical:
  fullnameOverride: infisical      # Service/Deployment named "infisical"
  replicaCount: 1
  image:
    tag: "v0.166.3"
  kubeSecretRef: infisical-secrets
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      memory: 1000Mi

ingress:
  enabled: false
  nginx:
    enabled: false

postgresql:
  enabled: false

redis:
  enabled: false
```

### 2.2 `infisical/manifests/postgres.yaml`

```yaml
# PostgreSQL 18 for Infisical (official image). Credentials: Secret "infisical-postgres" (not in git).
# postgres:18 keeps data under /var/lib/postgresql/18/docker, so the volume is mounted at
# /var/lib/postgresql and PGDATA is left at the image default.
apiVersion: v1
kind: Service
metadata:
  name: infisical-postgres
  namespace: infisical
  labels:
    app: infisical-postgres
spec:
  selector:
    app: infisical-postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: infisical-postgres
  namespace: infisical
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  serviceName: infisical-postgres
  replicas: 1
  selector:
    matchLabels:
      app: infisical-postgres
  template:
    metadata:
      labels:
        app: infisical-postgres
    spec:
      containers:
        - name: postgres
          image: postgres:18
          ports:
            - name: postgres
              containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: infisical
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef: {name: infisical-postgres, key: username}
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: {name: infisical-postgres, key: password}
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d infisical"]
            periodSeconds: 10
          resources:
            requests: {cpu: 100m, memory: 256Mi}
            limits: {memory: 512Mi}
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

### 2.3 `infisical/manifests/redis.yaml`

```yaml
# Redis 7.4 for Infisical (official image). Infisical requires Redis 6.x/7.x, persistence
# and maxmemory-policy noeviction (it stores job queues there). Password: Secret "infisical-redis".
apiVersion: v1
kind: Service
metadata:
  name: infisical-redis
  namespace: infisical
  labels:
    app: infisical-redis
spec:
  selector:
    app: infisical-redis
  ports:
    - name: redis
      port: 6379
      targetPort: 6379
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: infisical-redis
  namespace: infisical
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  serviceName: infisical-redis
  replicas: 1
  selector:
    matchLabels:
      app: infisical-redis
  template:
    metadata:
      labels:
        app: infisical-redis
    spec:
      containers:
        - name: redis
          image: redis:7.4
          args:
            - redis-server
            - --appendonly
            - "yes"
            - --maxmemory-policy
            - noeviction
            - --requirepass
            - $(REDIS_PASSWORD)
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef: {name: infisical-redis, key: password}
          ports:
            - name: redis
              containerPort: 6379
          readinessProbe:
            exec:
              command: ["sh", "-c", "redis-cli -a \"$REDIS_PASSWORD\" --no-auth-warning ping | grep -q PONG"]
            periodSeconds: 10
          resources:
            requests: {cpu: 50m, memory: 64Mi}
            limits: {memory: 256Mi}
          volumeMounts:
            - name: data
              mountPath: /data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 1Gi
```

### 2.4 `infisical/manifests/istio.yaml`

```yaml
# infisical.erminstudio.com: Cloudflare (TLS) -> istio-ingressgateway (HTTP :80, NodePort 30133) -> Infisical
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: infisical-gateway
  namespace: infisical
spec:
  selector:
    istio: ingressgateway
  servers:
    - hosts:
        - infisical.erminstudio.com
      port:
        name: http
        number: 80
        protocol: HTTP
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: infisical
  namespace: infisical
spec:
  gateways:
    - infisical-gateway
  hosts:
    - infisical.erminstudio.com
  http:
    # Cloudflare terminates TLS; restore the client-facing scheme (Envoy rewrites it to "http")
    - headers:
        request:
          set:
            X-Forwarded-Proto: https
            X-Forwarded-Port: "443"
      route:
        - destination:
            host: infisical.infisical.svc.cluster.local
            port:
              number: 8080
```

### 2.5 `argo/infisical-app.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: infisical
  namespace: argocd
spec:
  project: default
  sources:
    # Infisical Helm chart, with values from this repo
    - repoURL: https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/
      chart: infisical-standalone
      targetRevision: 1.11.0
      helm:
        releaseName: infisical
        valueFiles:
          - $values/infisical/values.yaml
    - repoURL: https://github.com/erminhalilovic700/kubecon-na-2025.git
      targetRevision: main
      ref: values
    # PostgreSQL 18, Redis 7.4 and Istio routing
    - repoURL: https://github.com/erminhalilovic700/kubecon-na-2025.git
      targetRevision: main
      path: infisical/manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: infisical
  # The chart stamps the Deployment with updatedAt: {{ now }} on every render.
  # Ignore it, or Argo CD would see a diff on every refresh and restart Infisical.
  ignoreDifferences:
    - group: apps
      kind: Deployment
      name: infisical
      jsonPointers:
        - /metadata/annotations/updatedAt
        - /spec/template/metadata/annotations/updatedAt
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - RespectIgnoreDifferences=true
```

---

## Part 3: Commit, push, register with Argo CD

```sh
cd ~/Projects/kubecon-na-2025
git status            # expect: infisical/ (4 files) and argo/infisical-app.yaml, nothing else
git add infisical argo/infisical-app.yaml
git commit -m "Add Infisical (Argo CD, PostgreSQL 18, Redis 7.4, Istio)"
git push origin main

kubectl apply -f argo/infisical-app.yaml
```

> Last time a file was missing from a commit. Check the `git commit` output says **5 files changed**.

Watch it come up. PostgreSQL and Redis start first (sync wave -1), then Infisical, which creates
its database tables on first start (about 1–2 min):

```sh
kubectl -n infisical get pods -w        # wait: infisical-postgres-0, infisical-redis-0, infisical-xxxxx all 1/1 Running
kubectl -n argocd get application infisical      # want: Synced  Healthy
```

---

## Part 4: Create your admin account (before it's public)

The **first account created becomes the server admin**. Create it through a private port-forward
**before** adding the Cloudflare route, so nobody on the internet can grab it first.

```sh
kubectl -n infisical port-forward svc/infisical 8080:8080
```

1. Open **http://localhost:8080** and create the admin account (your email + a strong password).
2. If it asks for an **email confirmation code**: there's no mail server, so Infisical prints the
   code to its log instead. In a second terminal:
   ```sh
   kubectl -n infisical logs deploy/infisical | grep -iE 'confirmation code|code:' | tail -3
   ```
3. Once in, open the **Server Admin Console** (`/admin`) → **General** → turn **off "Allow user
   signups"**. You'll invite other people yourself, and strangers can't register.
4. Stop the port-forward (Ctrl+C).

---

## Part 5: Expose it through Cloudflare

Cloudflare dashboard → **Networking → Tunnels → RancherAPI → Routes → Add route** →
**Published application**:

| Field | Value |
|---|---|
| Subdomain / Domain | `infisical` / `erminstudio.com` |
| Service type | **HTTP** (not HTTPS, the mistake from the Keycloak setup) |
| URL | `10.0.0.100:30133` |

This also creates the DNS record automatically. Then test:

```sh
curl -s https://infisical.erminstudio.com/api/status
```

You should get a small JSON response. Then open **https://infisical.erminstudio.com** and log in.

> If your browser says "site can't be reached", it's the router's DNS cache again (like with
> Keycloak). Wait about 15 minutes, or test from your phone on mobile data.

---

## Part 6: Keycloak

Infisical can't use Keycloak for free when self-hosted. Pick **one** option:

### Option B (recommended, free): Keycloak in front, through Cloudflare Access

Cloudflare Access asks for a **Keycloak login before anyone even reaches Infisical**. Infisical
keeps its own login behind that, which gives you two layers. It works for any app, and you could
reuse it for others later.

**B1. Keycloak client** (realm **Erminstudio** → **Clients** → **Create client**):

- Client ID `cloudflare-access` · Name `Cloudflare Access` → **Next**
- **Client authentication** On · **Standard flow** checked → **Next**
- **Valid redirect URIs:** `https://soft-mud-1502.cloudflareaccess.com/cdn-cgi/access/callback`
- **Save**, then copy the **Client secret** from the **Credentials** tab.

> `soft-mud-1502` is your Cloudflare Zero Trust team name (seen when `content.erminstudio.com`
> redirected to `soft-mud-1502.cloudflareaccess.com`). Confirm it in Zero Trust → Settings → Custom pages / Team domain.

**B2. Add Keycloak as a login method** (Cloudflare **Zero Trust** → **Settings** →
**Authentication** → **Login methods** → **Add new** → **OpenID Connect**):

| Field | Value |
|---|---|
| Name | `Keycloak` |
| App ID | `cloudflare-access` |
| Client secret | (from B1) |
| Auth URL | `https://keycloak.erminstudio.com/realms/erminstudio/protocol/openid-connect/auth` |
| Token URL | `https://keycloak.erminstudio.com/realms/erminstudio/protocol/openid-connect/token` |
| Certificate URL | `https://keycloak.erminstudio.com/realms/erminstudio/protocol/openid-connect/certs` |
| Proof Key for Code Exchange (PKCE) | On |
| OIDC Claims | `email` |

**Save**, then click **Test**. You should be sent to Keycloak, log in, and see a success page.

**B3. Protect Infisical** (Zero Trust → **Access** → **Applications** → **Add an application** → **Self-hosted**):

- Application name `Infisical` · Domain `infisical.erminstudio.com`
- **Login methods:** only **Keycloak**
- **Policy:** Action **Allow**, Include **Emails** → `ermin@halilovic.info`
- **Save**

Test in an incognito window: https://infisical.erminstudio.com → Cloudflare → **Keycloak login**
→ Infisical login page.

**B4. Show Infisical in the Keycloak account portal** (optional). The `cloudflare-access` client
is shared by every app behind Cloudflare Access, so it doesn't appear in the portal. Add a
link-only client (realm **Erminstudio** → **Clients** → **Create client**):

- Client ID `infisical-link` · Name `Infisical` → **Next**
- **Client authentication** Off · uncheck **every** authentication flow → **Next**
- **Root URL** `https://infisical.erminstudio.com` · **Home URL** `/` → **Save**
- **Settings** → **Always display in UI** On → **Save**

No one can log in through this client; it only adds the link at
https://keycloak.erminstudio.com/realms/erminstudio/account/applications.

> In-cluster apps that read secrets from Infisical (for example the Infisical Kubernetes operator)
> should use the internal address `http://infisical.infisical.svc.cluster.local:8080`, which
> doesn't go through Cloudflare Access. Only browsers and outside access go through Cloudflare.

### Option A (paid): Infisical's built-in Keycloak SSO

Only if you buy a self-hosted license from `sales@infisical.com`. It also requires **email domain
verification** (a DNS record for your email domain) before SSO logins work. With a license:

1. Keycloak (realm **Erminstudio**) → create client `infisical`: Client authentication On, Standard flow,
   Root/Home URL `https://infisical.erminstudio.com`,
   Valid redirect URI `https://infisical.erminstudio.com/api/v1/sso/oidc/callback`,
   Web origins `https://infisical.erminstudio.com`. In its dedicated client scope, add predefined
   mappers **email**, **given name**, **family name**. Copy the client secret.
2. Infisical → **Organization Settings → Single Sign-On (SSO)** → **OIDC → Connect** →
   Discovery URL `https://keycloak.erminstudio.com/realms/erminstudio/.well-known/openid-configuration`,
   algorithm **RS256**, client ID `infisical`, the secret → **Update** → **Enable**.
3. Test a login, and only then consider **Enforce OIDC SSO**. The emergency admin login is at `/login/admin`.

---

## Part 7: After install

- **Backups:** Infisical's data lives in `infisical-postgres`. Copy the Keycloak backup CronJob
  pattern: same file, with `PGHOST=infisical-postgres`, `PGDATABASE=infisical`, the
  `infisical-postgres` Secret and a `db/infisical/` prefix. Remember: **a database backup is useless
  without the ENCRYPTION_KEY** from Part 1.
- **Upgrades:** change `infisical.image.tag` in `infisical/values.yaml` (and/or `targetRevision`
  of the chart in `argo/infisical-app.yaml`), commit and push. Argo CD rolls it out, and Infisical
  migrates its database on start. Read Infisical's release notes before big jumps.

---

## Troubleshooting

| Symptom | Likely cause | Check / fix |
|---|---|---|
| `infisical` pod `CreateContainerConfigError` | a Secret from Part 1 missing | `kubectl -n infisical get secrets`: needs `infisical-secrets`, `infisical-postgres`, `infisical-redis` |
| `infisical` pod restarting, log shows DB errors | wrong DB password in `DB_CONNECTION_URI` | Delete all 3 secrets **and** the Postgres volume, then redo Part 1 (only before you've stored real data) |
| Log: Redis connection refused / NOAUTH | Redis not ready or password mismatch | `kubectl -n infisical logs infisical-redis-0` |
| Argo app constantly **OutOfSync** | `ignoreDifferences` missing or misspelled | compare `argo/infisical-app.yaml` with 2.5, then `kubectl apply -f argo/infisical-app.yaml` |
| Infisical pod **restarts every few minutes** | same as above (the `updatedAt` quirk) | same fix |
| Cloudflare **502** | tunnel route uses HTTPS or the wrong port | must be **HTTP** `10.0.0.100:30133` |
| Login loops or "insecure context" | header fix missing | the `headers:` block in `istio.yaml` (2.4) |
| Logs for anything | | `kubectl -n infisical logs deploy/infisical --tail=100` |

Ask Claude to verify after **Part 3** (pods and Argo app), **Part 5** (public URL) and **Part 6**.
