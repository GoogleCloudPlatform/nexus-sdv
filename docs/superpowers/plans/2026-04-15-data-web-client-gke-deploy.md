# Data Web Client — GKE Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy `sample-clients/data-web-client` to the GKE Autopilot cluster in the `sample-services` namespace behind a LoadBalancer, following existing Helm/Helmfile/GitHub Actions conventions.

**Architecture:** Multi-stage Node.js 22 Docker image using Next.js standalone output. Helm chart modelled on `data-api` with a Cloud SQL Auth Proxy sidecar (password auth, no `--auto-iam-authn`) for Cloud SQL connectivity. Secrets fetched from Google Secret Manager during CI and injected as Helm `--set` flags.

**Tech Stack:** Next.js 16 (standalone output), Node.js 22-alpine, Helm 3.19, Helmfile, GitHub Actions, GKE Autopilot, Cloud SQL Auth Proxy 2.18.0, Workload Identity Federation.

---

## Prerequisites (manual, before running the plan)

The following must exist before the workflow can run successfully:

| What | How |
|---|---|
| Terraform applied with `enable_web_client = true` | Provisions `nexus_acl` DB, `webclient` SQL user, `WEBCLIENT_DB_PASSWORD` Secret Manager entry |
| Secret Manager entry `NEXTAUTH_SECRET` | `openssl rand -base64 32 \| gcloud secrets create NEXTAUTH_SECRET --data-file=-` |
| Secret Manager entry `KEYCLOAK_CLIENT_SECRET` | Value from the Keycloak admin console for the `nexus-web-client` client |
| Secret Manager entry `NEXT_PUBLIC_GOOGLE_MAPS_API_KEY` | Google Maps JS API key (baked into the image at build time) |
| GitHub Actions variable `NEXTAUTH_URL` | `http://<LoadBalancer-IP>:3000` — set after first deployment (see bootstrap note below) |
| GitHub Actions variable `KEYCLOAK_CLIENT_ID` | `nexus-web-client` (or whatever client ID is configured in Keycloak) |
| GitHub Actions variable `KEYCLOAK_ISSUER` | Keycloak realm URL, e.g. `https://keycloak.example.com/realms/sdv-telemetry` |
| GitHub Actions variable `BIGTABLE_INSTANCE_ID` | e.g. `bigtable-production-storage` |
| GitHub Actions variable `CLOUD_SQL_INSTANCE_CONNECTION_NAME` | e.g. `my-project:europe-west1:nexus-sql` |
| GitHub Actions variable `NEXT_PUBLIC_GOOGLE_MAPS_MAP_ID` | Google Maps Map ID (non-sensitive, baked in at build time) |

> **Bootstrap note for `NEXTAUTH_URL`:** On the very first deploy, set `NEXTAUTH_URL` to a placeholder (e.g. `http://localhost:3000`). After the deployment, retrieve the LoadBalancer IP with `kubectl get svc -n sample-services`, update the GitHub variable, and re-run the workflow.

---

## File Map

| Action | Path | Purpose |
|---|---|---|
| Modify | `iac/terraform/iam.tf` | Add Cloud SQL client role + WIF binding for web client KSA |
| Modify | `sample-clients/data-web-client/next.config.ts` | Add `output: 'standalone'` |
| Create | `sample-clients/data-web-client/Dockerfile` | Multi-stage Node.js 22 build |
| Create | `iac/helm/data-web-client/Chart.yaml` | Chart metadata |
| Create | `iac/helm/data-web-client/values.yaml` | Default values (database URL constructed in template, not passed via --set) |
| Create | `iac/helm/data-web-client/templates/_helpers.tpl` | Naming helpers |
| Create | `iac/helm/data-web-client/templates/ksa.yaml` | Kubernetes Service Account with WIF annotation |
| Create | `iac/helm/data-web-client/templates/service.yaml` | LoadBalancer service on port 3000 |
| Create | `iac/helm/data-web-client/templates/deployment.yaml` | Pod with app container + Cloud SQL proxy sidecar |
| Create | `iac/helm/helmfile.d/data-web-client.yaml.gotmpl` | Helmfile release definition |
| Create | `.github/workflows/build-push-deploy-data-web-client.yml` | CI/CD pipeline |

---

## Task 1: Terraform IAM additions

**Files:**
- Modify: `iac/terraform/iam.tf`

- [ ] **Step 1: Append two IAM resources to `iac/terraform/iam.tf`**

Add these two blocks at the end of the file (after the last existing resource):

```hcl
resource "google_project_iam_member" "data_api_bigtable_connector_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.data_api_bigtable_connector.email}"
}

resource "google_service_account_iam_member" "workload_identity_user_data_web_client" {
  service_account_id = google_service_account.data_api_bigtable_connector.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[sample-services/data-web-client-ksa]"
}
```

- [ ] **Step 2: Verify Terraform can parse the file**

```bash
cd iac/terraform
terraform init -backend=false
terraform validate
```

Expected output: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add iac/terraform/iam.tf
git commit -m "feat(iac): grant sql.client role and WIF binding to web client KSA"
```

---

## Task 2: Next.js standalone output

**Files:**
- Modify: `sample-clients/data-web-client/next.config.ts`

- [ ] **Step 1: Add `output: 'standalone'` to `next.config.ts`**

Replace the file contents with:

```typescript
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: 'standalone',
  serverExternalPackages: ['@google-cloud/bigtable'],
};

export default nextConfig;
```

- [ ] **Step 2: Verify the build produces a standalone directory**

```bash
cd sample-clients/data-web-client
npm run build
```

Expected: build completes without errors. Verify `ls .next/standalone/` shows `server.js` and `node_modules/`.

- [ ] **Step 3: Commit**

```bash
git add sample-clients/data-web-client/next.config.ts
git commit -m "feat(data-web-client): enable standalone output for Docker deployment"
```

---

## Task 3: Dockerfile

**Files:**
- Create: `sample-clients/data-web-client/Dockerfile`

- [ ] **Step 1: Create the Dockerfile**

```dockerfile
FROM node:22-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
ARG NEXT_PUBLIC_GOOGLE_MAPS_API_KEY
ARG NEXT_PUBLIC_GOOGLE_MAPS_MAP_ID
ENV NEXT_PUBLIC_GOOGLE_MAPS_API_KEY=$NEXT_PUBLIC_GOOGLE_MAPS_API_KEY
ENV NEXT_PUBLIC_GOOGLE_MAPS_MAP_ID=$NEXT_PUBLIC_GOOGLE_MAPS_MAP_ID
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

- [ ] **Step 2: Verify the image builds locally**

```bash
cd sample-clients/data-web-client
docker build -t data-web-client:test .
```

Expected: build completes, final image is created. Run `docker images data-web-client` to confirm it exists.

- [ ] **Step 3: Commit**

```bash
git add sample-clients/data-web-client/Dockerfile
git commit -m "feat(data-web-client): add multi-stage Docker build with standalone output"
```

---

## Task 4: Helm chart scaffolding

**Files:**
- Create: `iac/helm/data-web-client/Chart.yaml`
- Create: `iac/helm/data-web-client/values.yaml`
- Create: `iac/helm/data-web-client/templates/_helpers.tpl`

- [ ] **Step 1: Create `iac/helm/data-web-client/Chart.yaml`**

```yaml
apiVersion: v2
name: data-web-client
description: A Helm chart for the Data Web Client
type: application
version: 0.1.0
appVersion: "latest"
```

- [ ] **Step 2: Create `iac/helm/data-web-client/values.yaml`**

```yaml
image:
  repository: ""
  pullPolicy: IfNotPresent
  tag: "latest"

service:
  type: LoadBalancer
  port: 3000

gcp:
  projectId: ""
  serviceAccountEmail: ""

database:
  instanceConnectionName: ""
  name: "nexus_acl"
  user: "webclient"
  password: ""

nextauth:
  secret: ""
  url: ""

keycloak:
  clientId: ""
  clientSecret: ""
  issuer: ""

bigtable:
  instanceId: ""
```

- [ ] **Step 3: Create `iac/helm/data-web-client/templates/_helpers.tpl`**

```
{{- define "data-web-client.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "data-web-client.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "data-web-client.labels" -}}
helm.sh/chart: {{ include "data-web-client.name" . }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "data-web-client.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "data-web-client.selectorLabels" -}}
app.kubernetes.io/name: {{ include "data-web-client.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

- [ ] **Step 4: Commit**

```bash
git add iac/helm/data-web-client/
git commit -m "feat(iac): scaffold data-web-client Helm chart (Chart.yaml, values, helpers)"
```

---

## Task 5: Helm chart templates

**Files:**
- Create: `iac/helm/data-web-client/templates/ksa.yaml`
- Create: `iac/helm/data-web-client/templates/service.yaml`
- Create: `iac/helm/data-web-client/templates/deployment.yaml`

- [ ] **Step 1: Create `iac/helm/data-web-client/templates/ksa.yaml`**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: data-web-client-ksa
  labels:
    {{- include "data-web-client.labels" . | nindent 4 }}
  annotations:
    iam.gke.io/gcp-service-account: {{ .Values.gcp.serviceAccountEmail | quote }}
```

- [ ] **Step 2: Create `iac/helm/data-web-client/templates/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "data-web-client.fullname" . }}
  labels:
    {{- include "data-web-client.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    {{- include "data-web-client.selectorLabels" . | nindent 4 }}
```

- [ ] **Step 3: Create `iac/helm/data-web-client/templates/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "data-web-client.fullname" . }}
  labels:
    {{- include "data-web-client.labels" . | nindent 4 }}
spec:
  replicas: 1
  selector:
    matchLabels:
      {{- include "data-web-client.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "data-web-client.selectorLabels" . | nindent 8 }}
    spec:
      serviceAccountName: data-web-client-ksa
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 3000
              protocol: TCP
          env:
            - name: NEXTAUTH_SECRET
              value: {{ .Values.nextauth.secret | quote }}
            - name: NEXTAUTH_URL
              value: {{ .Values.nextauth.url | quote }}
            - name: KEYCLOAK_CLIENT_ID
              value: {{ .Values.keycloak.clientId | quote }}
            - name: KEYCLOAK_CLIENT_SECRET
              value: {{ .Values.keycloak.clientSecret | quote }}
            - name: KEYCLOAK_ISSUER
              value: {{ .Values.keycloak.issuer | quote }}
            - name: BIGTABLE_PROJECT_ID
              value: {{ .Values.gcp.projectId | quote }}
            - name: BIGTABLE_INSTANCE_ID
              value: {{ .Values.bigtable.instanceId | quote }}
            - name: DATABASE_URL
              value: "postgresql://{{ .Values.database.user }}:{{ .Values.database.password }}@localhost:5432/{{ .Values.database.name }}"
        {{- if .Values.database.instanceConnectionName }}
        - name: cloud-sql-proxy
          image: "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.18.0"
          args:
            - "--structured-logs"
            - "--health-check"
            - "--http-address=0.0.0.0"
            - "--http-port=9090"
            - "{{ .Values.database.instanceConnectionName }}"
          ports:
            - name: health
              containerPort: 9090
              protocol: TCP
          startupProbe:
            httpGet:
              path: /startup
              port: 9090
              scheme: HTTP
            initialDelaySeconds: 5
            periodSeconds: 2
            failureThreshold: 30
            timeoutSeconds: 5
          livenessProbe:
            httpGet:
              path: /liveness
              port: 9090
              scheme: HTTP
            periodSeconds: 10
            failureThreshold: 3
            timeoutSeconds: 10
          readinessProbe:
            httpGet:
              path: /readiness
              port: 9090
              scheme: HTTP
            periodSeconds: 10
            failureThreshold: 6
            initialDelaySeconds: 10
            timeoutSeconds: 10
          securityContext:
            runAsNonRoot: true
          resources:
            requests:
              memory: "128Mi"
              cpu: "50m"
            limits:
              memory: "256Mi"
              cpu: "100m"
        {{- end }}
```

- [ ] **Step 4: Verify the chart passes lint**

```bash
helm lint iac/helm/data-web-client \
  --set image.repository=test \
  --set gcp.serviceAccountEmail=test@project.iam.gserviceaccount.com \
  --set database.instanceConnectionName=project:region:instance \
  --set database.password=pass \
  --set nextauth.secret=secret \
  --set nextauth.url=http://localhost:3000 \
  --set keycloak.clientId=nexus-web-client \
  --set keycloak.clientSecret=secret \
  --set keycloak.issuer=https://keycloak.example.com/realms/sdv-telemetry \
  --set bigtable.instanceId=bigtable-production-storage \
  --set gcp.projectId=my-project
```

Expected output: `1 chart(s) linted, 0 chart(s) failed`

- [ ] **Step 5: Commit**

```bash
git add iac/helm/data-web-client/templates/
git commit -m "feat(iac): add data-web-client Helm templates (ksa, service, deployment)"
```

---

## Task 6: Helmfile template

**Files:**
- Create: `iac/helm/helmfile.d/data-web-client.yaml.gotmpl`

- [ ] **Step 1: Create `iac/helm/helmfile.d/data-web-client.yaml.gotmpl`**

```yaml
releases:
  - name: data-web-client
    namespace: sample-services
    createNamespace: true
    chart: '../data-web-client'
    labels:
      app: data-web-client
    installed: true
    set:
      - name: image.repository
        value: '{{ requiredEnv "IMAGE_REPO" }}/data-web-client'
      - name: gcp.projectId
        value: '{{ requiredEnv "GCP_PROJECT_ID" }}'
      - name: gcp.serviceAccountEmail
        value: '{{ requiredEnv "DATA_API_BIGTABLE_CONNECTOR_GCP_SERVICE_ACCOUNT" }}'
      - name: database.instanceConnectionName
        value: '{{ requiredEnv "CLOUD_SQL_INSTANCE_CONNECTION_NAME" }}'
      - name: database.password
        value: '{{ requiredEnv "WEBCLIENT_DB_PASSWORD" }}'
      - name: nextauth.secret
        value: '{{ requiredEnv "NEXTAUTH_SECRET" }}'
      - name: nextauth.url
        value: '{{ requiredEnv "NEXTAUTH_URL" }}'
      - name: keycloak.clientId
        value: '{{ requiredEnv "KEYCLOAK_CLIENT_ID" }}'
      - name: keycloak.clientSecret
        value: '{{ requiredEnv "KEYCLOAK_CLIENT_SECRET" }}'
      - name: keycloak.issuer
        value: '{{ requiredEnv "KEYCLOAK_ISSUER" }}'
      - name: bigtable.instanceId
        value: '{{ requiredEnv "BIGTABLE_INSTANCE_ID" }}'
```

- [ ] **Step 2: Commit**

```bash
git add iac/helm/helmfile.d/data-web-client.yaml.gotmpl
git commit -m "feat(iac): add helmfile release template for data-web-client"
```

---

## Task 7: GitHub Actions workflow

**Files:**
- Create: `.github/workflows/build-push-deploy-data-web-client.yml`

- [ ] **Step 1: Create `.github/workflows/build-push-deploy-data-web-client.yml`**

```yaml
name: Build, Push and Deploy the Data Web Client

on:
  workflow_dispatch:
    inputs:
      environment:
        description: "Environment (sandbox, dev, ...)"
        required: true
      helmAction:
        type: choice
        description: "Sets the action for the helmfile plugin: 'sync' forces an update and 'apply' checks for differences"
        required: false
        default: "sync"
        options:
          - apply
          - sync

  workflow_call:
    inputs:
      environment:
        type: string
        required: true

permissions:
  id-token: write
  contents: read

env:
  DOCKER_BUILD_SUMMARY: false
  GKE_CLUSTER_NAME: "${{ inputs.environment }}-gke"

jobs:
  deploy-data-web-client:
    name: Deploy the Data Web Client
    runs-on: ${{ vars.RUNNER_LABEL || 'ubuntu-latest' }}
    environment: ${{ inputs.environment }}

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure Google Cloud Auth
        uses: google-github-actions/auth@v2
        with:
          token_format: access_token
          workload_identity_provider: projects/${{ vars.GCP_PROJECT_NUMBER }}/locations/global/workloadIdentityPools/${{ vars.GCP_WORKLOAD_IDENTITY_POOL_ID }}/providers/${{ vars.GCP_WORKLOAD_IDENTITY_PROVIDER_ID }}
          service_account: ${{ vars.GCP_SERVICE_ACCOUNT }}

      - name: Import secrets
        uses: google-github-actions/get-secretmanager-secrets@v3
        with:
          secrets: |-
            IMAGE_REPO:projects/${{ vars.GCP_PROJECT_ID }}/secrets/IMAGE_REPO/versions/latest
            DATA_API_BIGTABLE_CONNECTOR_GCP_SERVICE_ACCOUNT:projects/${{ vars.GCP_PROJECT_ID }}/secrets/DATA_API_BIGTABLE_CONNECTOR_GCP_SERVICE_ACCOUNT/versions/latest
            WEBCLIENT_DB_PASSWORD:projects/${{ vars.GCP_PROJECT_ID }}/secrets/WEBCLIENT_DB_PASSWORD/versions/latest
            NEXTAUTH_SECRET:projects/${{ vars.GCP_PROJECT_ID }}/secrets/NEXTAUTH_SECRET/versions/latest
            KEYCLOAK_CLIENT_SECRET:projects/${{ vars.GCP_PROJECT_ID }}/secrets/KEYCLOAK_CLIENT_SECRET/versions/latest
            NEXT_PUBLIC_GOOGLE_MAPS_API_KEY:projects/${{ vars.GCP_PROJECT_ID }}/secrets/NEXT_PUBLIC_GOOGLE_MAPS_API_KEY/versions/latest
          export_to_environment: true

      - name: Docker auth
        run: |-
          gcloud auth configure-docker ${{ vars.GCP_REGION }}-docker.pkg.dev --quiet

      - name: Build and Push Data Web Client
        uses: docker/build-push-action@v6
        with:
          push: true
          tags: ${{ env.IMAGE_REPO }}/data-web-client:latest
          file: ./sample-clients/data-web-client/Dockerfile
          context: ./sample-clients/data-web-client
          build-args: |
            NEXT_PUBLIC_GOOGLE_MAPS_API_KEY=${{ env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY }}
            NEXT_PUBLIC_GOOGLE_MAPS_MAP_ID=${{ vars.NEXT_PUBLIC_GOOGLE_MAPS_MAP_ID }}
          provenance: false
          sbom: false

      - name: Get GKE credentials and write kubeconfig
        uses: google-github-actions/get-gke-credentials@v2
        with:
          cluster_name: ${{ env.GKE_CLUSTER_NAME }}
          location: ${{ vars.GCP_REGION }}
          use_dns_based_endpoint: true

      - name: Deploy Data Web Client
        uses: helmfile/helmfile-action@v2.0.4
        env:
          GCP_PROJECT_ID: ${{ vars.GCP_PROJECT_ID }}
          GCP_REGION: ${{ vars.GCP_REGION }}
          IMAGE_REPO: ${{ env.IMAGE_REPO }}
          DATA_API_BIGTABLE_CONNECTOR_GCP_SERVICE_ACCOUNT: ${{ env.DATA_API_BIGTABLE_CONNECTOR_GCP_SERVICE_ACCOUNT }}
          WEBCLIENT_DB_PASSWORD: ${{ env.WEBCLIENT_DB_PASSWORD }}
          NEXTAUTH_SECRET: ${{ env.NEXTAUTH_SECRET }}
          NEXTAUTH_URL: ${{ vars.NEXTAUTH_URL }}
          KEYCLOAK_CLIENT_ID: ${{ vars.KEYCLOAK_CLIENT_ID }}
          KEYCLOAK_CLIENT_SECRET: ${{ env.KEYCLOAK_CLIENT_SECRET }}
          KEYCLOAK_ISSUER: ${{ vars.KEYCLOAK_ISSUER }}
          BIGTABLE_INSTANCE_ID: ${{ vars.BIGTABLE_INSTANCE_ID }}
          CLOUD_SQL_INSTANCE_CONNECTION_NAME: ${{ vars.CLOUD_SQL_INSTANCE_CONNECTION_NAME }}
        with:
          helm-version: "v3.19.0"
          helmfile-workdirectory: iac/helm/helmfile.d
          helmfile-args: --file data-web-client.yaml.gotmpl ${{ inputs.helmAction || 'apply' }}
```

- [ ] **Step 2: Verify YAML is valid**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-push-deploy-data-web-client.yml'))" && echo "YAML valid"
```

Expected: `YAML valid`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build-push-deploy-data-web-client.yml
git commit -m "feat(ci): add build-push-deploy workflow for data-web-client"
```
