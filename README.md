# Dakiya Tracking

Parcel tracking service. Depots and riders send scan events, customers check status.

## Run locally

    docker-compose up

API is on http://localhost:8000

## Deploy

Every push goes through CI and deploys to prod automatically.

The Helm chart in `deploy/` is for the Kubernetes migration. WIP, not tested yet.

Ask Bilal if something breaks.
