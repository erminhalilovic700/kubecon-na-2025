# content.erminstudio.com → Argo CD + Keycloak SSO

Two parts. **Part A** moves `content.erminstudio.com` (MinIO) into Argo CD with no change in behaviour.
**Part B** adds Keycloak login. Finish Part A and confirm it's healthy before starting Part B,
so that if something breaks you know which step caused it.

**What's running now** (everything was applied by hand with `kubectl`; no Helm release, nothing in git):

- **MinIO server:** StatefulSet `minio` (`ermin700/minio`) with a 20Gi volume
- **MinIO Console:** Deployment `minio-console` (`ermin700/console:v1.7.6`), which is what `content.erminstudio.com` serves
- **Routing:** Gateway `content-gateway` and Certificate `content-cert` in `istio-system`, VirtualService `content` in `minio`

---

## Part A: Move content to Argo

Work in `~/Projects/erminstudio` and run `git pull` first.

### A1. Create `minio/minio.yaml` (MinIO server)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio
spec:
  selector:
    app: minio
  ports:
    - name: s3
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: minio
  namespace: minio
  labels:
    app: minio
spec:
  serviceName: minio
  replicas: 1
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: minio
          image: ermin700/minio:RELEASE.2025-10-15T17-29-55Z-eql.2
          args: ["server", "/data", "--address", ":9000", "--console-address", ":9001"]
          env:
            - name: MINIO_ROOT_USER
              valueFrom:
                secretKeyRef: {name: minio-credentials, key: rootUser}
            - name: MINIO_ROOT_PASSWORD
              valueFrom:
                secretKeyRef: {name: minio-credentials, key: rootPassword}
            - name: MINIO_BROWSER_REDIRECT_URL
              value: https://content.erminstudio.com
          ports:
            - {name: s3, containerPort: 9000}
            - {name: console, containerPort: 9001}
          livenessProbe:
            httpGet: {path: /minio/health/live, port: 9000}
            initialDelaySeconds: 10
            periodSeconds: 20
          readinessProbe:
            httpGet: {path: /minio/health/ready, port: 9000}
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests: {cpu: 100m, memory: 256Mi}
            limits: {memory: 1Gi}
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
            storage: 20Gi
```

> ⚠️ Keep `volumeClaimTemplates` exactly as shown (20Gi, `local-path`). Kubernetes won't let that
> section of a StatefulSet change, so any difference makes the sync fail.

### A2. Create `minio/console.yaml` (MinIO Console)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: minio-console
  namespace: minio
spec:
  selector:
    app: minio-console
  ports:
    - name: http
      port: 9090
      targetPort: 9090
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio-console
  namespace: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio-console
  template:
    metadata:
      labels:
        app: minio-console
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
      containers:
        - name: console
          image: ermin700/console:v1.7.6-eql.1
          args: ["server"]
          env:
            - name: CONSOLE_MINIO_SERVER
              value: http://minio.minio.svc.cluster.local:9000
            - name: CONSOLE_PBKDF_PASSPHRASE
              valueFrom:
                secretKeyRef: {name: minio-console-secret, key: CONSOLE_PBKDF_PASSPHRASE}
            - name: CONSOLE_PBKDF_SALT
              valueFrom:
                secretKeyRef: {name: minio-console-secret, key: CONSOLE_PBKDF_SALT}
          ports:
            - {name: http, containerPort: 9090}
          readinessProbe:
            httpGet: {path: /ready, port: 9090}
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests: {cpu: 50m, memory: 128Mi}
            limits: {memory: 512Mi}
```

### A3. Create `minio/istio.yaml` (routing and certificate, copied from live)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: content-cert
  namespace: istio-system
spec:
  secretName: content-tls
  dnsNames:
    - content.erminstudio.com
  issuerRef:
    kind: ClusterIssuer
    name: rancher-ca-issuer
---
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: content-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
    - hosts: [content.erminstudio.com]
      port: {name: http, number: 80, protocol: HTTP}
    - hosts: [content.erminstudio.com]
      port: {name: https, number: 443, protocol: HTTPS}
      tls:
        mode: SIMPLE
        credentialName: content-tls
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: content
  namespace: minio
spec:
  gateways: [istio-system/content-gateway]
  hosts: [content.erminstudio.com]
  http:
    - route:
        - destination:
            host: minio-console.minio.svc.cluster.local
            port:
              number: 9090
```

### A4. Create `minio/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - minio.yaml
  - console.yaml
  - istio.yaml
```

> Don't add a `namespace:` line, unlike Keycloak's kustomization. The routing objects must stay in
> `istio-system`, and that line would move them all into `minio`.

### A5. Check before committing (nothing gets changed)

```sh
kubectl diff -k minio/
```

You want to see **no output**, or only annotation and label lines. If it shows changes to `image`,
`env`, `volumeClaimTemplates` or ports, stop and check with Claude.

### A6. Create `argo/minio-app.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: minio
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/erminhalilovic700/erminstudio.git
    targetRevision: main
    path: minio
  destination:
    server: https://kubernetes.default.svc
    namespace: minio
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### A7. Commit, push, register

```sh
git add minio argo/minio-app.yaml
git commit -m "Manage MinIO / content.erminstudio.com with Argo CD"
git push origin main
kubectl apply -f argo/minio-app.yaml
```

### A8. Verify

```sh
kubectl -n argocd get application minio      # want: Synced  Healthy
kubectl -n minio get pods                    # same pods, no restarts
```

Then open https://content.erminstudio.com; it should look exactly as before.
**Checkpoint:** ask Claude to verify before starting Part B.

---

## Part B: Log in to content with Keycloak

MinIO has built-in OpenID support. You give MinIO's server Keycloak's details, and the console shows
a **Login with SSO** button. Keycloak tells MinIO which permission level to grant, using MinIO's
built-in levels: `consoleAdmin`, `readwrite` and `readonly`.

### B1. Create the client in Keycloak (admin console)

Switch the realm dropdown to **Erminstudio**, then go to **Clients** → **Create client**:

1. **Client type:** OpenID Connect. **Client ID:** `minio`. **Name:** `MinIO`. Click **Next**.
2. Turn **Client authentication** on and keep **Standard flow** checked. Click **Next**.
3. Fill in:
   - **Root URL:** `https://content.erminstudio.com`
   - **Valid redirect URIs:** `https://content.erminstudio.com/oauth_callback`
   - **Web origins:** `https://content.erminstudio.com`
4. Click **Save**.

### B2. Add roles matching MinIO's permission levels

In the `minio` client, open the **Roles** tab → **Create role** three times:
`consoleAdmin`, `readwrite`, `readonly`. The names are case-sensitive and must match exactly.

### B3. Send the roles to MinIO in the login token

In the `minio` client, go to **Client scopes** → **minio-dedicated** → **Configure a new mapper** →
**User Client Role**:

- **Name:** `minio-policy`
- **Client ID:** `minio`
- **Token Claim Name:** `policy`
- **Multivalued:** on
- **Claim JSON Type:** String
- **Add to ID token**, **Add to access token** and **Add to userinfo:** all on

Click **Save**.

### B4. Give yourself admin access

Go to **Users** → `ermin@halilovic.info` → **Role mapping** → **Assign role** →
**Filter by clients**. Tick `minio consoleAdmin` → **Assign**.

### B5. Store the client secret in the cluster

In the `minio` client, open the **Credentials** tab and copy the **Client secret**. Then run:

```sh
kubectl -n minio create secret generic minio-oidc --from-literal=client_secret='PASTE_SECRET_HERE'
```

Don't put the secret in git.

### B6. Check MinIO can reach Keycloak's public URL

MinIO exchanges the login code with Keycloak at its public address:

```sh
kubectl -n minio run nettest --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s -o /dev/null -w '%{http_code}\n' https://keycloak.erminstudio.com/realms/erminstudio/.well-known/openid-configuration
```

You want `200`.

### B7. Add the OpenID settings to MinIO (edit `minio/minio.yaml`)

Add these under the existing `env:` of the `minio` container, after `MINIO_BROWSER_REDIRECT_URL`:

```yaml
            - name: MINIO_IDENTITY_OPENID_CONFIG_URL
              value: http://keycloak-service.keycloak.svc.cluster.local:8080/realms/erminstudio/.well-known/openid-configuration
            - name: MINIO_IDENTITY_OPENID_CLIENT_ID
              value: minio
            - name: MINIO_IDENTITY_OPENID_CLIENT_SECRET
              valueFrom:
                secretKeyRef: {name: minio-oidc, key: client_secret}
            - name: MINIO_IDENTITY_OPENID_CLAIM_NAME
              value: policy
            - name: MINIO_IDENTITY_OPENID_SCOPES
              value: openid,profile,email
            - name: MINIO_IDENTITY_OPENID_DISPLAY_NAME
              value: Keycloak
            - name: MINIO_IDENTITY_OPENID_REDIRECT_URI
              value: https://content.erminstudio.com/oauth_callback
```

### B8. Apply the same HTTPS header fix as Keycloak (edit `minio/istio.yaml`)

Cloudflare forwards plain HTTP, and Istio rewrites the header that says the original request was
HTTPS. Restore it in the `content` VirtualService by changing its `http:` section to:

```yaml
  http:
    - headers:
        request:
          set:
            X-Forwarded-Proto: https
            X-Forwarded-Port: "443"
      route:
        - destination:
            host: minio-console.minio.svc.cluster.local
            port:
              number: 9090
```

### B9. Check, commit, push

```sh
kubectl diff -k minio/        # should show only the new env vars and the headers block
git add minio
git commit -m "MinIO: SSO via Keycloak"
git push origin main
```

> ⚠️ `minio-0` restarts when Argo syncs, so S3 is unavailable for about 20–30 seconds.
> Anything using `content-app-credentials` will notice that brief gap.

### B10. Test

In an incognito window, open https://content.erminstudio.com and click
**Login with SSO (Keycloak)**. Sign in as `ermin@halilovic.info`, and you should land in the
console as admin. The root user login still works as a fallback.

If something fails, these show what went wrong:

```sh
kubectl -n minio logs minio-0 | grep -i openid
kubectl -n minio logs deploy/minio-console | tail -20
kubectl -n keycloak logs keycloak-0 | grep -i 'clientId="minio"'
```

> One uncertainty: the console is a custom build (`ermin700/console`). Standard Console v1.7.x reads
> the SSO settings from the MinIO server automatically. If the **Login with SSO** button doesn't
> appear after B9, check with Claude what this build expects.
