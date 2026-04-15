# Data Web Client — GKE Deployment Design

**Date:** 2026-04-15
**Branch:** feat/keycloak-acl-clean
**Status:** Approved

---

## Goal

Deploy `sample-clients/data-web-client` (Next.js 16, next-auth, BigTable, Cloud SQL) to the existing GKE Autopilot cluster, following established Helm/Helmfile/GitHub Actions conventions.

---

## Deployment Target

- **Cluster:** existing GKE Autopilot cluster (private nodes, public control plane)
- **Namespace:** `sample-services`
- **Exposure:** `LoadBalancer` service on port 3000 — static IP assigned by the cluster (local installation strategy, no external-dns or Ingress)

---

## 1. Terraform Changes (`iac/terraform/iam.tf`)

Reuse the existing `data_api_bigtable_connector` GCP Service Account. Two bindings are appended:

```hcl
# Grant Cloud SQL client role to the shared GSA
resource "google_project_iam_member" "data_api_bigtable_connector_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.data_api_bigtable_connector.email}"
}

# Bind web client KSA to the same GSA via Workload Identity
resource "google_service_account_iam_member" "workload_identity_user_data_web_client" {
  service_account_id = google_service_account.data_api_bigtable_connector.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[sample-services/data-web-client-ksa]"
}
```

No new GSA or variables needed. The `data_api_bigtable_connector` GSA already holds `roles/bigtable.reader`; this adds `roles/cloudsql.client` and registers the new KSA.

---

## 2. Dockerfile (`sample-clients/data-web-client/Dockerfile`)

Multi-stage build using Next.js standalone output mode. Requires `output: 'standalone'` in `next.config.ts`.

```dockerfile
FROM node:22-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
EXPOSE 3000
CMD ["node", "server.js"]
```

The final image contains only the compiled Next.js standalone output — no build tooling, no full `node_modules`.

---

## 3. Helm Chart (`iac/helm/data-web-client/`)

Mirrors the `data-api` chart structure, with a Cloud SQL Auth Proxy sidecar added (same proxy version and pattern as `iac/helm/keycloak/`).

### File Structure

```
Chart.yaml
values.yaml
templates/
  _helpers.tpl
  deployment.yaml    ← main container + cloud-sql-proxy sidecar
  service.yaml       ← LoadBalancer, port 3000
  ksa.yaml           ← KSA with workload identity annotation
```

### `values.yaml` Shape

```yaml
image:
  repository: ""
  tag: "latest"

service:
  type: LoadBalancer
  port: 3000

gcp:
  projectId: ""
  serviceAccountEmail: ""     # data-api-bigtable-connector GSA email

database:
  instanceConnectionName: ""  # project:region:instance
  name: "nexus_acl"
  user: "webclient"
  password: ""                # injected at deploy time from Secret Manager

nextauth:
  secret: ""                  # injected at deploy time from Secret Manager
  url: ""

keycloak:
  clientId: ""
  clientSecret: ""            # injected at deploy time from Secret Manager
  issuer: ""

bigtable:
  instanceId: ""
```

### Cloud SQL Proxy Sidecar

Uses password authentication (no `--auto-iam-authn`). The main container connects to `localhost:5432`. Same proxy image version as Keycloak (`gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.18.0`).

---

## 4. Helmfile Template (`iac/helm/helmfile.d/data-web-client.yaml.gotmpl`)

Follows the same structure as `data-api.yaml.gotmpl`. Releases into `sample-services` namespace. All sensitive values are passed as Helm `--set` flags resolved from environment variables set by the GitHub Actions workflow.

---

## 5. GitHub Actions Workflow (`.github/workflows/build-push-deploy-data-web-client.yml`)

Mirrors `build-push-deploy-data-api.yml`. Key differences:

| | `data-api` | `data-web-client` |
|---|---|---|
| Build context | `base-services/data-api/` | `sample-clients/data-web-client/` |
| Extra secrets fetched | `DATA_API_BIGTABLE_CONNECTOR_GCP_SERVICE_ACCOUNT` | same + `WEBCLIENT_DB_PASSWORD`, `NEXTAUTH_SECRET`, `KEYCLOAK_CLIENT_SECRET` |
| Helmfile template | `data-api.yaml.gotmpl` | `data-web-client.yaml.gotmpl` |
| Proto compilation step | yes | no |

Trigger: manual `workflow_dispatch` with `environment` and `helmAction` inputs — same as all other service workflows.

---

## Secret Management

All secrets are fetched from Google Secret Manager during CI using the existing GitHub OIDC service account. They are passed as Helm `--set` flags and become environment variables in the pod. Secrets required:

| Secret Manager ID | Used for |
|---|---|
| `WEBCLIENT_DB_PASSWORD` | Cloud SQL password auth (already provisioned by Terraform) |
| `NEXTAUTH_SECRET` | NextAuth.js session signing key (needs to be created) |
| `KEYCLOAK_CLIENT_SECRET` | OIDC client secret (from Keycloak admin) |

`KEYCLOAK_CLIENT_ID`, `KEYCLOAK_ISSUER`, `BIGTABLE_INSTANCE_ID`, `BIGTABLE_PROJECT_ID`, and `NEXTAUTH_URL` are non-sensitive and passed as plain Helm values via the helmfile template.

---

## Prerequisites Before Deployment

1. Terraform applied with `enable_web_client = true` (provisions `nexus_acl` DB + `webclient` user + `WEBCLIENT_DB_PASSWORD` secret)
2. `NEXTAUTH_SECRET` created in Secret Manager (generate with `openssl rand -base64 32`)
3. Keycloak client configured for the web client (client ID + secret available)
4. Terraform applied with the two new IAM bindings from section 1
