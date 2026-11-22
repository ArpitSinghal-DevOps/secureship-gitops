# secureship-gitops

Desired state for the SecureShip platform, synced to the cluster by Argo CD.
The application and its CI pipeline live in [secureship-app](https://github.com/ArpitSinghal-DevOps/secureship-app).

```
argocd/
  root.yaml              app-of-apps; the only thing applied by hand
  apps/kyverno.yaml      Kyverno 1.20 admission controller      (sync wave -2)
  apps/policies.yaml     policies/ folder                        (wave -1)
  apps/secureship.yaml   chart/secureship                        (wave 0)
  optional/monitoring.yaml  in-cluster kube-prometheus-stack (heavier alternative)
chart/secureship/        hardened Helm chart: Deployment, Service, NetworkPolicy,
                         read-only metrics ServiceAccount, Grafana dashboard
monitoring/              Prometheus + Grafana config for the Docker setup
                         (tools/monitoring up: scrapes pods via the API server proxy)
policies/
  verify-image-signature.yaml   ImageValidatingPolicy: every image (app, init, ephemeral
                                containers) must be signed by the secureship-app workflow
                                on main and carry an SBOM attested by it
  kyverno-rbac.yaml             lets Kyverno read pods/ephemeralcontainers (policy readiness)
  pod-hardening.yaml            ValidatingPolicy: digest-pinned images, CPU/memory
                                limits, non-root, no privilege escalation, read-only FS
                                (init containers included); no ephemeral debug containers
tests/                   Kyverno CLI tests for the policies (run in CI)
tests/signature/         signature + SBOM tests against real images (needs network)
scripts/bootstrap.sh     minikube + Argo CD bootstrap (needs only Docker)
tools/                   containerised CLIs: k (kubectl), run (gh/git/cosign/yq), minikube,
                         monitoring (Prometheus + Grafana containers)
```

`chart/secureship/values.yaml → image.digest` is written by the app pipeline after the image is
scanned and signed. Nobody edits it by hand.

## CI (`.github/workflows/lint.yml`)

- `helm lint` and render
- Trivy config scan of the chart (HIGH/CRITICAL fails)
- Kyverno policy unit tests, including real signed and unsigned images
- The rendered chart's pod template checked against the pod-hardening policy (fails if nothing was evaluated)

## Bootstrap

```bash
./scripts/bootstrap.sh            # env: CPUS=4 MEMORY=5g ARGOCD_VERSION=v3.6.2
tools/k -n argocd get applications
```

Full guide: [SETUP.md](SETUP.md).
