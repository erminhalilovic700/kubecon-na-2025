# Argo CD SSO with Keycloak

Goal: log in to **https://deploy.erminstudio.com** (Argo CD v3.7.0) with **Keycloak**
(realm **Erminstudio**). Membership in a Keycloak group decides your Argo CD role.

**Current setup:**

- **Install:** Argo CD was installed with plain `kubectl apply` manifests (no Helm, not in git), so
  its settings are changed with `kubectl patch` on the `argocd` namespace's ConfigMaps/Secret.
- **URL:** `argocd-cm` already has `url: https://deploy.erminstudio.com`, which Argo CD needs to
  build the login callback.
- **Routing:** Cloudflare tunnel → `https://10.0.0.100:31677` → Istio `argocd-gateway` (HTTPS) →
  `argocd-server`. Unlike Keycloak and MinIO, this route doesn't need the `X-Forwarded-Proto` header fix.
- **Approach:** Argo CD's built-in OIDC (`oidc.config`). Dex is not used.

The local `admin` login keeps working the whole time as a fallback.

---

## Part 1: Keycloak (admin console)

Open https://keycloak.erminstudio.com/admin and switch the realm dropdown (top left) to **Erminstudio**.

### 1.1 Create the client

**Clients** → **Create client**:

1. **Client type:** OpenID Connect · **Client ID:** `argocd` · **Name:** `Argo CD` → **Next**
2. **Client authentication:** **On** · **Standard flow:** checked · everything else unchecked → **Next**
3. Fill in:
   - **Root URL:** `https://deploy.erminstudio.com`
   - **Home URL:** `/applications`
   - **Valid redirect URIs:** `https://deploy.erminstudio.com/auth/callback`
   - **Valid post logout redirect URIs:** `https://deploy.erminstudio.com/*`
   - **Web origins:** `https://deploy.erminstudio.com`
4. **Save**

### 1.2 Copy the client secret

`argocd` client → **Credentials** tab → copy **Client secret**. You'll need it in step 2.1.

### 1.3 Create a `groups` client scope (puts group names in the login token)

**Client scopes** → **Create client scope**:

- **Name:** `groups` · **Type:** None · **Include in token scope:** On → **Save**

Then in that scope: **Mappers** tab → **Configure a new mapper** → **Group Membership**:

- **Name:** `groups`
- **Token Claim Name:** `groups`
- **Full group path:** **Off** (otherwise the group arrives as `/ArgoCDAdmins` and the RBAC in
  step 2.3 won't match)
- **Add to ID token** / **Add to access token** / **Add to userinfo:** On

→ **Save**

### 1.4 Attach the scope to the client

**Clients** → `argocd` → **Client scopes** tab → **Add client scope** → tick `groups` →
**Add** → **Optional**. Argo CD explicitly asks for `groups` at login, so **Optional** is enough.

### 1.5 Create the groups and add yourself

**Groups** → **Create group**:

- `ArgoCDAdmins` → full admin in Argo CD
- `ArgoCDViewers` → read-only (optional, for other people later)

Then **Users** → `ermin@halilovic.info` → **Groups** tab → **Join group** → tick `ArgoCDAdmins` → **Join**.

---

## Part 2: Argo CD (from your terminal)

### 2.1 Store the client secret in `argocd-secret`

Argo CD reads secrets referenced as `$<key>` from the `argocd-secret` Secret. Paste the secret from 1.2:

```sh
kubectl -n argocd patch secret argocd-secret \
  --patch='{"stringData": {"oidc.keycloak.clientSecret": "PASTE_SECRET_HERE"}}'
```

Check that the key exists (prints the length only, not the secret):

```sh
kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.oidc\.keycloak\.clientSecret}' | base64 -d | wc -c
```

### 2.2 Add the OIDC config to `argocd-cm`

Create a file `argocd-cm-oidc.yaml` (anywhere, e.g. `~/Desktop`):

```yaml
data:
  oidc.config: |
    name: Keycloak
    issuer: https://keycloak.erminstudio.com/realms/erminstudio
    clientID: argocd
    clientSecret: $oidc.keycloak.clientSecret
    requestedScopes: ["openid", "profile", "email", "groups"]
    logoutURL: https://keycloak.erminstudio.com/realms/erminstudio/protocol/openid-connect/logout?id_token_hint={{token}}&post_logout_redirect_uri={{logoutRedirectURL}}
```

Apply it. This merges into the existing ConfigMap and keeps `url` and the other keys:

```sh
kubectl -n argocd patch configmap argocd-cm --patch-file argocd-cm-oidc.yaml
```

> Keep `issuer` as the **public** URL, exactly as above. It must match the `iss` value in
> Keycloak's tokens, so the in-cluster `keycloak-service` URL won't work here.

### 2.3 Map Keycloak groups to Argo CD roles in `argocd-rbac-cm`

Create `argocd-rbac-oidc.yaml`:

```yaml
data:
  scopes: '[groups]'
  policy.csv: |
    g, ArgoCDAdmins, role:admin
    g, ArgoCDViewers, role:readonly
```

Apply it:

```sh
kubectl -n argocd patch configmap argocd-rbac-cm --patch-file argocd-rbac-oidc.yaml
```

Users who log in through Keycloak without either group get **no access**. That's Argo CD v3's
default and is what you want.

### 2.4 Make Argo CD pick it up

`argocd-server` usually reloads these ConfigMaps by itself within a few seconds. To be sure:

```sh
kubectl -n argocd rollout restart deploy/argocd-server
kubectl -n argocd rollout status deploy/argocd-server
```

---

## Part 3: Test

1. Check that Argo CD sees the OIDC config (no login needed):

   ```sh
   curl -s https://deploy.erminstudio.com/api/v1/settings | python3 -m json.tool | grep -A6 oidcConfig
   ```

   You should see `"name": "Keycloak"` and the `issuer`.

2. Open https://deploy.erminstudio.com in an **incognito window** → click **LOG IN VIA KEYCLOAK**
   → sign in as `ermin@halilovic.info` (Erminstudio password).

3. You should land on the Applications page and see `keycloak`, `grafana`, `minio`, etc.
   Open **User Info** (left sidebar). It should list your username and the group `ArgoCDAdmins`.

4. Click **Log out**. You should be sent through Keycloak's logout and back to the Argo CD login page.

### If something fails

| Symptom | Likely cause | Check |
|---|---|---|
| No "Log in via Keycloak" button | `oidc.config` not loaded / YAML indentation | `kubectl -n argocd logs deploy/argocd-server \| grep -i oidc` |
| Keycloak says **Invalid redirect uri** | redirect URI typo in 1.1 | must be exactly `https://deploy.erminstudio.com/auth/callback` |
| "failed to get token" / "invalid client" after login | wrong secret in 2.1 | redo 2.1 with the secret from the Credentials tab |
| Logged in but **no apps / permission denied** | `groups` claim missing or full path on | **User Info** page: groups should show `ArgoCDAdmins`. Recheck 1.3 (Full group path **Off**), 1.4, 1.5 |
| Keycloak events | anything Keycloak-side | `kubectl -n keycloak logs keycloak-0 \| grep 'clientId="argocd"'` |

---

## Later (optional)

- **Disable the local `admin` account** once SSO works reliably. Keep it until you're sure:
  ```sh
  kubectl -n argocd patch configmap argocd-cm --patch='{"data": {"admin.enabled": "false"}}'
  ```
- **CLI login via SSO** (`argocd login deploy.erminstudio.com --sso`) needs a separate **public**
  Keycloak client with PKCE (`cliClientID` in `oidc.config`). It's not covered here; the CLI can
  keep using the `admin` account or an API token for now.
- **Manage Argo CD's own config in git.** These ConfigMap changes live only in the cluster, like
  Grafana's did before it moved to Argo. A re-install from `install.yaml` would overwrite them.
