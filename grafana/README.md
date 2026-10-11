# Grafana

Grafana in the `observability` namespace, exposed at https://grafana.erminstudio.com
(Cloudflare tunnel -> Istio `grafana-gateway`), with SSO through Keycloak.

Installed with Helm directly (not Argo CD). `values.yaml` is the full set of values,
so upgrades don't need `--reuse-values`:

```sh
helm repo add grafana https://grafana.github.io/helm-charts
helm -n observability upgrade --install grafana grafana/grafana \
  --version 10.5.15 -f grafana/values.yaml
```

## Secrets (created out-of-band, not in git)

- `grafana-admin` – local admin login (`admin-user`, `admin-password`)
- `grafana-oauth` – `client_secret` of the Keycloak `grafana` client
  (Keycloak admin console → realm *Erminstudio* → Clients → grafana → Credentials):

  ```sh
  kubectl -n observability create secret generic grafana-oauth \
    --from-literal=client_secret='<client secret>'
  ```

## Keycloak SSO

- Realm `erminstudio`, confidential client `grafana` (PKCE S256)
- Redirect URI `https://grafana.erminstudio.com/login/generic_oauth`
- Client roles `admin` / `editor` / `viewer` map to Grafana Admin / Editor / Viewer
  (users without a role get Viewer). A protocol mapper puts them in the `roles` claim.
- The local `admin` login still works as a fallback.
