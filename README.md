# Dakiya Tracking — DevOps Take-Home

Dakiya is a parcel-tracking service consisting of a FastAPI API, a background worker, Redis for queued scan events, and PostgreSQL for persistent tracking data. This repository contains Docker Compose, a reusable Helm chart, GitHub Actions CI, and Argo CD Applications for staging, production, and a retail-partner environment.

> **Evidence:** The [`evidence/`](evidence/) directory contains screenshots documenting the completed work, including the successful CI workflow, API access, Kubernetes workloads and storage, and Argo CD applications/resource views. The screenshots support the claims in this README; they do not replace live CI or pull-request links.


## Findings and remediation

This table compares the initial repository supplied for the assignment with the implementation in this repository. “Verified” refers only to the checks described in the evidence column; it does not imply production readiness.

| Finding in initial repository | Risk | Change made | Status / evidence |
|---|---|---|---|
| CI used `pytest || true`. | Tests could fail while the pipeline continued to build and publish images. | CI runs the API pytest suite in a separate required job; image build/scan/push depends on it. | **Implemented in workflow.** Add a link to a successful CI run below to prove it ran successfully. |
| The test for rejecting an unknown scan status failed because the API schema accepted arbitrary strings. | Invalid scan statuses could be accepted instead of rejected at request validation. | Constrained `ScanEvent.status` to the supported status values using a `Literal` type so invalid values return HTTP 422; updated the test expectation accordingly. | **Code/test fix made.** Confirmed by the successful CI screenshot; include the live run URL below. |
| A local `.env` file containing environment configuration was pushed to the repository. | Environment values, potentially including credentials, could be exposed in source control. | Removed the `.env` file from the tracked working tree and updated `.gitignore` to exclude `.env` and common Python virtual-environment/cache files. | **Repository hygiene improved.** If the file contained a real secret, rotate it; adding `.env` to `.gitignore` does not erase it from Git history. |
| The API did not expose dedicated health/readiness endpoints. | Operators and orchestrators had no simple HTTP checks for API liveness/readiness. | Added `/health` and `/readiness` endpoints to the API application. | **Implemented.** Verify both endpoints against the running application before claiming runtime validation. |
| CI ran on every push, used floating action references, pushed `latest` images, and directly SSH-deployed to production. | Unreviewed changes could reach production; mutable tags obscure exactly what was deployed; SSH key handling and disabled host-key checking weaken deployment security. | The updated workflow is triggered on pushes to `assignment`, uses SHA tags, publishes to GHCR, and updates staging desired image tags in Git. It does not directly apply Kubernetes resources or SSH to production. | **Workflow changed.** Production/partner promotion is intended to happen through Git changes; repository branch protection and required approvals must be configured and verified separately. |
| API Dockerfile used `python:latest`, passed `DB_PASSWORD` as a build argument, and enabled Uvicorn reload. | Floating base image, possible secret exposure in build metadata/history, and development-mode behavior in a deployment image. | API image uses Python 3.11 slim, a multi-stage build, a non-root user, and runtime configuration for credentials. | **Implemented in Dockerfile.** No independent image security audit is claimed. |
| Worker Dockerfile used `python:latest` and installed extra tools (`vim`, `curl`) into the runtime image. | Less reproducible builds and a larger attack surface. | Worker image uses Python 3.11 slim, a multi-stage build, and a non-root user. | **Implemented in Dockerfile.** |
| Compose used floating `postgres:latest`/`redis:latest`, hard-coded a database password, had no named data volumes or health checks, and did not make worker depend on Redis. | Unintended version changes, credential exposure, loss of local data on container recreation, and startup races. | Compose configuration adds runtime environment configuration, named volumes, health checks, and service dependencies. | **Implemented in configuration.** Verify startup, persistence after recreation, and service health on the target machine. |
| The original Helm values were incomplete and used hard-coded database credentials and floating image tags. | Environment drift, secrets in source control, and uncertain repeatability. | A reusable chart now has environment-specific values files, Secret integration, optional image pull secrets, and persistent PostgreSQL/Redis storage. | **Chart rendered and deployed through Argo CD in the observed kind cluster.** Standalone Helm should also be checked with the commands below. |
| There was no working Argo CD Application structure for staging, production, and retail partner. | No clear GitOps reconciliation or separate desired state per environment. | Three Argo CD Application manifests and a kind bootstrap script were added. CI updates staging image tags in Git; Argo CD reconciles the desired state. | **Observed:** all three Applications reported `Synced` and `Healthy`. Actual branch protection/review enforcement and promotion PR are not evidenced yet. |
| Worker exits when the Redis blocking read raises a socket timeout. | Background scan processing may stop and Kubernetes repeatedly restarts the worker. | No verified fix is included in the observed implementation. | **Open.** Previous staging worker logs showed `redis.exceptions.TimeoutError: Timeout reading from socket` at `r.brpop("scans")`; workers showed three restarts in each environment. |
| Trivy findings do not currently block publication. | Images with HIGH/CRITICAL findings may still be published. | Trivy image scanning is configured for HIGH and CRITICAL severity. | **Partly addressed.** The workflow currently sets `exit-code: "0"`, so scanning is informational, not a blocking gate. A severity policy remains to be chosen. |
| No verifiable deployment, promotion, or end-to-end scan evidence was included in the initial README. | Reviewers cannot independently reproduce or confirm the claimed behavior. | README and implementation notes describe reproducible commands and the observed cluster state. | **Partly addressed.** Add real CI/PR/evidence links below and test a scan end to end before claiming complete functional verification. |

## How to run locally with Docker Compose

Run these commands from the repository root (`dakiya/`). Ensure Docker Engine and the Docker Compose plugin are installed.

1. Create your local environment file from the example, then edit `.env` and replace the example values with the appropriate values for your environment. Do not commit `.env`.

   ```bash
   cp .env.example .env
   nano .env
   ```

   Update the values in `.env` as needed, including `DB_USER`, `DB_PASSWORD`, and `DB_NAME`. Use a strong local password and keep real credentials out of source control.

2. Build and start the stack:

   ```bash
   docker compose up --build -d
   ```

3. Inspect service status and logs:

   ```bash
   docker compose ps
   docker compose logs --tail=100 api worker postgres redis
   ```

4. Check the API root, health, and readiness endpoints:

   ```bash
   curl -i http://localhost:8000/
   curl -i http://localhost:8000/health
   curl -i http://localhost:8000/readiness
   ```

5. Stop the services while retaining named volumes:

   ```bash
   docker compose down
   ```

   `docker compose down -v` deletes the Compose-managed volumes and their data. Use it only when intentionally resetting local data.

## How to run Helm without Argo CD

The chart is intended to remain independently usable. From the repository root:

```bash
helm lint ./deploy/helm/dakiya \
  -f ./deploy/helm/dakiya/values-staging.yaml

helm template dakiya-release ./deploy/helm/dakiya \
  -n dakiya-staging \
  -f ./deploy/helm/dakiya/values-staging.yaml
```

Before installing, create or configure the Kubernetes Secret expected by the selected values and ensure the image tags are pullable by the cluster. Then run:

```bash
helm upgrade --install dakiya-release ./deploy/helm/dakiya \
  -n dakiya-staging --create-namespace \
  -f ./deploy/helm/dakiya/values-staging.yaml
```

Check the release and resources:

```bash
helm status dakiya-release -n dakiya-staging
kubectl get pods,pvc,svc -n dakiya-staging
```

## How to bootstrap GitOps on a local kind cluster

Prerequisites: `kind`, `kubectl`, and `helm` are installed; a kind cluster already exists; the current kubectl context points to that cluster; and the repository/image credentials are configured if Git or GHCR packages are private.

From the repository root:

```bash
chmod +x scripts/bootstrap-argocd-kind.sh
./scripts/bootstrap-argocd-kind.sh
```

The script installs/configures Argo CD in the existing cluster and applies the three Application definitions. It does not create a kind cluster or grant credentials for private repositories/packages.

Check synchronization and workload state:

```bash
kubectl get applications -n argocd
kubectl get pods -n dakiya-staging
kubectl get pods -n dakiya-production
kubectl get pods -n dakiya-retail-partner
kubectl get pvc -A
```

For detailed application status:

```bash
kubectl describe application dakiya-staging -n argocd
kubectl describe application dakiya-production -n argocd
kubectl describe application dakiya-retail-partner -n argocd
```

Optional Argo CD UI access:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080`. Retrieve the initial admin password locally (do not paste it into logs or commit it):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

### Intended release flow

1. A push to `assignment` triggers CI.
2. The test job runs before the image build/scan/push job.
3. The workflow publishes API and worker images with commit-SHA tags and a mutable `latest` tag.
4. After those jobs succeed, CI updates `deploy/helm/dakiya/values-staging.yaml` to the triggering commit SHA and commits that change to Git.
5. Argo CD reconciles staging from Git.
6. Production and retail-partner versions are intended to be changed through separately reviewed Git changes to their environment values files. The review gate must be configured in repository settings; Application YAML by itself does not enforce human approval.

The workflow does not directly deploy to a Kubernetes cluster. Trivy scans HIGH/CRITICAL findings but is currently configured with `exit-code: "0"`, so findings do not fail publication.

## Evidence

Screenshots supplied with this submission are stored in [`evidence/`](evidence/). They are ordered to tell the story from CI through Kubernetes and Argo CD. They are supporting evidence, not substitutes for the live GitHub run/PR URLs requested below.

1. **CI workflow run — successful run shown:** [01-ci-success.png](evidence/01-ci-success.png). This screenshot shows a successful GitHub Actions run with the test and image build/push jobs completed. Add the actual run URL here: `TODO: paste the GitHub Actions run URL`.
2. **Staging Kubernetes workloads:** [02-staging-pods.png](evidence/02-staging-pods.png). Terminal output shows the staging API, PostgreSQL, Redis, and worker pods.
3. **API endpoint response:** [03-api-response.png](evidence/03-api-response.png). Browser response from the local API endpoint.
4. **Port-forward command / API access setup:** [04-staging-port-forward.png](evidence/04-staging-port-forward.png). Terminal screenshot showing the API port-forward command.
5. **API interactive documentation:** [05-api-docs.png](evidence/05-api-docs.png). Shows the FastAPI/OpenAPI interface was accessible.
6. **Argo CD login page:** [06-argocd-login.png](evidence/06-argocd-login.png). Shows the local Argo CD UI was opened; no credentials are included.
7. **Argo CD Applications overview:** [07-argocd-applications.png](evidence/07-argocd-applications.png). Shows the three environment Applications in the UI.
8. **Argo CD application resource tree:** [08-argocd-resource-tree.png](evidence/08-argocd-resource-tree.png). Shows resources tracked by an Application.
9. **Additional resource-tree view:** [09-argocd-resource-tree-detail.png](evidence/09-argocd-resource-tree-detail.png).
10. **Additional Argo CD resource view:** [10-argocd-resource-tree-wide.png](evidence/10-argocd-resource-tree-wide.png).
11. **Kubernetes resources and PVCs:** [11-kubernetes-resources-pvcs.png](evidence/11-kubernetes-resources-pvcs.png). Terminal output includes workloads and storage resources.

- **Green CI pipeline URL:** `TODO — add the actual GitHub Actions run URL; do not use the screenshot as a replacement for the link.`
- **Production promotion pull request URL:** `TODO — add the real PR URL after creating/reviewing/merging the production values change.`
- **End-to-end scan proof:** Not yet captured. The evidence currently demonstrates CI status, API endpoint access, Kubernetes resources, PVC binding, and Argo CD UI/resource reconciliation. It does not prove a scan event was consumed by the worker and persisted in PostgreSQL.

Observed kind-cluster state at the time of inspection:
- `dakiya-staging`, `dakiya-production`, and `dakiya-retail-partner` reported `Synced` / `Healthy`.
- API, worker, PostgreSQL, and Redis pods showed `Running` and `1/1 Ready`.
- PostgreSQL and Redis PVCs were `Bound` in all three namespaces.
- Each worker had three restarts; the previous staging worker log showed a Redis socket timeout. Therefore, the screenshots support successful resource reconciliation and readiness at that point in time, but **not** stable worker operation or end-to-end scan processing.

## AI usage

Update this disclosure to match your actual usage before submitting. Based on the work session, an honest draft is:

- **Gemini:** For initial plan, updated the configuraitons even tried for HELM but its making stuff complex.

- **ChatGPT:** Used to help reason through Helm chart structure, Argo CD GitOps flow, CI design, troubleshooting, and documentation wording.
- **Human verification:** Commands and outputs from the local kind cluster were reviewed to distinguish observed results from assumptions.
- **Incorrect AI suggestion encountered:** An earlier suggestion treated the worker's Redis socket timeout mainly as an uncaught blocking-read timeout and proposed a sample loop. That sample was not verified against the full worker logic and should not be represented as a tested fix. The worker timeout remains open until the existing job-processing code is changed and retested.
Also Gemini was writing credentials hardcoded to the HELM and ArgoCD.


## Time spent

Enter your actual time, rounded reasonably. Do not use invented estimates:

| Task | Actual time |
|---|---:| Started at 6PM
| Task 1 — Docker/Compose and container hardening | `Completed: 1 hours` |
| Task 2 — CI tests, image build/scan/publish | `TODO: 1 hours` |
| Task 3 — Helm chart and kind validation | `TODO: 3 hours` |
| Task 4 — Argo CD GitOps and environment configuration | `TODO: 2 hours` |
| Task 5 — design, README, implementation notes, and verification | `TODO: 1 hours` |
| **Total** | **Completed: 9 hours** |

## Remaining limitations

- Fix and verify worker Redis timeout handling without discarding its existing scan-processing logic.
- Decide on a blocking vulnerability policy for Trivy.