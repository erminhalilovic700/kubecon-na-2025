# Argo CD configuration (SSO via Keycloak)

Argo CD itself is installed with the upstream `install.yaml` (not managed by Argo CD or this repo),
so these files are **`kubectl patch` files**, not manifests that anything syncs automatically.
Re-apply them after any Argo CD reinstall or version change, because `install.yaml` resets
`argocd-cm` and `argocd-rbac-cm`.

| File | Patches | What it does |
|---|---|---|
| `argocd-cm-oidc.yaml` | `argocd-cm` | Login via Keycloak (realm `erminstudio`, client `argocd`) |
| `argocd-rbac-oidc.yaml` | `argocd-rbac-cm` | Keycloak group `ArgoCDAdmins` → `role:admin`, `ArgoCDViewers` → `role:readonly` |

```sh
kubectl -n argocd patch configmap argocd-cm      --patch-file argocd/argocd-cm-oidc.yaml
kubectl -n argocd patch configmap argocd-rbac-cm --patch-file argocd/argocd-rbac-oidc.yaml
kubectl -n argocd rollout restart deploy/argocd-server
```

`argocd-cm` must also keep `url: https://deploy.erminstudio.com` (set at install time).

## Not in git

- **Client secret:** `argocd-secret` key `oidc.keycloak.clientSecret` (referenced as
  `$oidc.keycloak.clientSecret`). It holds the Keycloak `argocd` client's secret from
  Keycloak → realm Erminstudio → Clients → argocd → Credentials. `install.yaml` doesn't overwrite it.
- **Keycloak side** (realm `erminstudio`): confidential client `argocd` (redirect URI
  `https://deploy.erminstudio.com/auth/callback`), optional client scope `groups` with a Group
  Membership mapper (claim `groups`, full path off), groups `ArgoCDAdmins` / `ArgoCDViewers`.

The local `admin` account still works as a fallback.
