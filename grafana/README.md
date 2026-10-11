# Grafana

Grafana in the `observability` namespace, exposed at https://grafana.erminstudio.com
(Cloudflare tunnel -> Istio `grafana-gateway`), with SSO through Keycloak.
The Istio Gateway and VirtualService are in `values.yaml` under `extraObjects`.

Deployed by Argo CD (`argo/grafana-app.yaml`): the `grafana/grafana` chart 10.5.15 with
`values.yaml` from this repo. To change Grafana, edit `values.yaml` (or bump
`targetRevision` in the Application) and push to `main`. Don't run `helm upgrade` by hand.

The Grafana PVC is annotated so Argo CD never prunes or deletes it.

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
