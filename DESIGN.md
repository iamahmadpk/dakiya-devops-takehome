# Dakiya Deployment Design

## Goals and scope

Dakiya accepts parcel scan events through a FastAPI API, queues work in Redis, and persists application data in PostgreSQL. The implementation makes the service runnable with Docker Compose, packages it for Kubernetes with Helm, and describes the desired state of staging, production, and a retail-partner environment through Argo CD.

This is a take-home implementation and local `kind` demonstration, not evidence of production-scale performance, high availability, disaster recovery, or a completed security audit.

## Runtime architecture

```text
Client / depot
     |
     v
 FastAPI API  -------> Redis queue (scans)
     |                         |
     |                         v
     +------------------ PostgreSQL <--- Worker
                                  
Docker Compose (local) OR Kubernetes (kind)
```

The API and worker are separate container images. Redis is used for queued scan work and PostgreSQL for persistent application data. Compose uses named volumes for PostgreSQL and Redis and health checks for the backing services. The Helm chart deploys the API, worker, PostgreSQL, and Redis, with persistent volume claims for database and Redis data. Kubernetes namespaces isolate the three environment instances.

## Image build and delivery

The GitHub Actions workflow is configured for pushes to the `assignment` branch. It runs the API test suite, builds API and worker images, scans the built images with Trivy, and publishes SHA-tagged images to GitHub Container Registry (GHCR). It also publishes a `latest` tag. The Trivy step currently uses `exit-code: "0"`, so findings are reported but do not block image publication; this is an explicit limitation, not an enforced vulnerability gate.

After the test and image jobs succeed, the workflow updates the API and worker tags in `deploy/helm/dakiya/values-staging.yaml` to the triggering commit SHA and pushes that Git change. The workflow does not use Kubernetes credentials or deploy directly to a cluster.

## GitOps and promotion

One Helm chart is reused by three Argo CD Applications:

| Environment | Namespace | Desired values |
|---|---|---|
| Staging | `dakiya-staging` | `values-staging.yaml` |
| Production | `dakiya-production` | `values-production.yaml` |
| Retail partner | `dakiya-retail-partner` | `values-retail-partner.yaml` |

Argo CD watches the Git repository and applies the chart. The Application definitions enable automated synchronization, pruning, and self-healing. Staging image tags are advanced by CI. Production and retail-partner image tags are intended to be promoted by reviewed changes to their respective values files, keeping the promotion decision in Git. The same chart can also be installed directly with Helm; Argo CD is not a prerequisite for using the chart.

## Configuration and security boundaries

Environment-specific values are separated from shared templates. Database credentials are supplied through Kubernetes Secrets; existing Secret support allows a deployment to reuse a pre-created Secret rather than storing a live password in a values file. Do not commit real credentials. For private GHCR packages, the cluster needs registry-pull credentials; the bootstrap instructions do not make private images publicly accessible automatically.

The API and worker images use Python 3.11 slim-based multi-stage builds and a non-root application user (UID/GID 10001). These are baseline hardening measures; they do not replace image maintenance, least-privilege Kubernetes policies, network policies, secret rotation, or a vulnerability policy that fails builds when required.

## Persistence and failure behavior

PostgreSQL and Redis use PVC-backed storage in Kubernetes. PVCs being `Bound` proves claims were provisioned, not that backups or restore procedures work. Kubernetes restarts failed containers, but application-level retry behavior still matters: during verification, worker logs showed an uncaught Redis socket timeout while waiting on `BRPOP`, and the worker had restarted three times in each environment. That issue must be fixed and re-tested before describing the worker as stable. Argo CD reporting an Application `Healthy` does not prove that a scan was processed end to end.

## Verification boundaries

On the local `kind` cluster, the three Applications were observed as `Synced` and `Healthy`; API, worker, PostgreSQL, and Redis pods were `Running`/`Ready`, and all six environment PVCs were `Bound`. The worker restart counts and Redis timeout described above remain a known issue. No claim is made here that production traffic, partner connectivity, automated pull-request approval rules, backup recovery, or a complete end-to-end scan workflow has been verified.
