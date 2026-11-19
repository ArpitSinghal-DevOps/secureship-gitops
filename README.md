# secureship-gitops

Desired state for the SecureShip platform, synced to the cluster by Argo CD.
The application and its CI pipeline live in [secureship-app](https://github.com/ArpitSinghal-DevOps/secureship-app).

```
argocd/
  root.yaml              app-of-apps; the only thing applied by hand
  apps/kyverno.yaml      Kyverno 1.20 admission controller      (sync wave -2)
  apps/policies.yaml     policies/ folder                        (wave -1)
  apps/secureship.yaml   chart/secureship                        (wave 0)
  optional/monitoring.yaml  kube-prometheus-stack; move into apps/ to enable
chart/secureship/        hardened Helm chart: Deployment, Service, NetworkPolicy,
                         ServiceMonitor, Grafana dashboard
policies/
  verify-image-signature.yaml   ImageValidatingPolicy: only images signed by the
                                secureship-app workflow on main may run
  pod-hardening.yaml            ValidatingPolicy: digest-pinned images, CPU/memory
                                limits, non-root, no privilege escalation, read-only FS
tests/                   Kyverno CLI tests for the policies (run in CI)
scripts/bootstrap.sh     minikube + Argo CD bootstrap (needs only Docker)
tools/                   containerised CLIs: k (kubectl), run (gh/git/cosign/yq), minikube
```

`chart/secureship/values.yaml → image.digest` is written by the app pipeline after the image is
scanned and signed. Nobody edits it by hand.

## CI (`.github/workflows/lint.yml`)

- `helm lint` and render
- Trivy config scan of the chart (HIGH/CRITICAL fails)
- Kyverno policy unit tests, plus the rendered chart checked against the pod-hardening policy

## Bootstrap

```bash
./scripts/bootstrap.sh            # env: CPUS=4 MEMORY=5g ARGOCD_VERSION=v3.6.2
tools/k -n argocd get applications
```

Full guide: [SETUP.md](SETUP.md).
