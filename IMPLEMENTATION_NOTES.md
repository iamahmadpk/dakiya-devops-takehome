# Implementation Notes

## Summary

This repository adapts the Dakiya service for repeatable local and Kubernetes deployment and introduces a GitOps release structure. This document distinguishes implementation present in the repository from behavior directly observed during the local kind session.

## Implemented

- Docker Compose defines API, worker, PostgreSQL, and Redis services, named volumes for PostgreSQL and Redis, health checks for the backing services, and service dependencies.
- API and worker Dockerfiles use Python 3.11 slim-based multi-stage builds and create a non-root application user with UID/GID 10001. Database credentials are supplied at runtime rather than as Docker build arguments.
- The Helm chart in `deploy/helm/dakiya/` templates the API, worker, PostgreSQL, Redis, services, Secret integration, and persistent storage. It supports environment-specific values files and optional registry pull-secret configuration.
- `.github/workflows/ci.yml` is configured for pushes to `assignment`. It runs the API pytest suite, builds API and worker images, runs Trivy image scans, pushes images to GHCR with commit-SHA and `latest` tags, and then updates the staging values file to the triggering SHA.
- CI does not use Kubernetes credentials or apply resources to a cluster. The staging image-version change is committed to Git for Argo CD to reconcile.
- Three Argo CD Application definitions target `dakiya-staging`, `dakiya-production`, and `dakiya-retail-partner`, each using the shared Helm chart with its own values file. The bootstrap script installs Argo CD on an existing kind cluster and applies the Applications.
- `DESIGN.md` records the architecture, delivery flow, boundaries, and known limitations. `README.md` provides local, Helm, and GitOps commands.

## Verification observed

The user ran `scripts/bootstrap-argocd-kind.sh` and then collected `kubectl get applications -n argocd`, `kubectl get pods -A`, and `kubectl get pvc -A` output.

Observed results at that point:

- All three Argo CD Applications reported `Synced` and `Healthy`.
- API, worker, PostgreSQL, and Redis pods across the three application namespaces were `Running` and showed `1/1 Ready`.
- The production API had two replicas; staging and retail-partner had one API replica each.
- PostgreSQL and Redis PVCs were `Bound` in all three namespaces.
- The worker in each namespace showed three restarts.
- The previous staging worker logs showed an uncaught `redis.exceptions.TimeoutError: Timeout reading from socket` at `r.brpop("scans")` in `worker.py`. This demonstrates that the worker can exit when the Redis blocking read times out; the restart count is not zero.

These checks verify that the Applications reconciled and Kubernetes resources were created and ready at the time of observation. They do **not** establish successful processing of a scan from API through Redis, worker, and PostgreSQL. They also do not verify CI execution in GitHub, GHCR pull access from a fresh cluster, production-grade security, disaster recovery, load behavior, or partner connectivity.

## Outstanding issues and caveats

1. **Worker timeout handling:** Fix the Redis blocking-read/socket-timeout behavior while preserving the existing job-processing logic. Then rebuild/publish the worker image, update the staging image SHA through the intended GitOps flow, and verify the restart count remains stable during an idle queue and during job processing. Repeat in other environments after promotion.
2. **Database credentials and initialized PVCs:** PostgreSQL may retain the password initialized on the first startup. Updating a Kubernetes Secret alone does not change the password stored inside an already-initialized database. Keep the Secret aligned with the database or use a controlled password-rotation procedure. Do not delete PVCs to work around authentication issues unless intentionally discarding data.
3. **Image-scan policy:** Trivy is configured with `exit-code: "0"`, so findings do not currently fail the workflow. Decide the severity threshold and remediation policy before treating the scan as a gate.
4. **Production/partner promotion:** The intended control is a reviewed Git change to the environment values file. Repository branch protection and required review settings must be configured in GitHub; YAML alone does not enforce approvals.
5. **Private images/repository:** Private GHCR images need a Kubernetes image pull secret, and private Git repositories need Argo CD repository credentials. Configure these out of band; never commit tokens or passwords.
6. **Evidence and timing:** No CI run URL, pull-request URL, screenshot path, or total implementation time is included because none was established in the verification record used to write this file. Add only real links/evidence and an honest time estimate before submission.

## Suggested final acceptance checks

Run these after fixing the worker and ensuring the desired image tags are pinned:

```bash
helm lint ./deploy/helm/dakiya -f ./deploy/helm/dakiya/values-staging.yaml
helm template dakiya-release ./deploy/helm/dakiya -n dakiya-staging -f ./deploy/helm/dakiya/values-staging.yaml
kubectl get applications -n argocd
kubectl get pods -A
kubectl get pvc -A
kubectl logs -n dakiya-staging deployment/dakiya-release-worker --previous
```

Then submit a real scan event, verify the worker consumes it and PostgreSQL reflects the expected result, test a controlled Argo CD self-heal drift, and verify that production/partner promotion requires the repository's configured review process. Record the actual commands and outputs; do not mark these as completed until observed.
