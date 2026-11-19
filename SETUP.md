# SecureShip: step-by-step setup

Run `../setup.sh` from the parent `secureship/` folder. Everything here is free: public GitHub repos get free Actions minutes and free GHCR storage,
Sigstore signing is free, and the cluster runs locally on minikube.

Time needed: about 1 to 1.5 hours the first time.

```
secureship/
├── setup.sh             one-time: fills in your GitHub username, runs git init
├── secureship-app/      FastAPI app + secure CI pipeline   -> GitHub repo #1
└── secureship-gitops/   Helm chart, Argo CD, Kyverno, monitoring -> GitHub repo #2
```

---

## Step 1: Install prerequisites (Ubuntu)

Docker is already installed. Install minikube and kubectl:

```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube && rm minikube-linux-amd64

curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

minikube version && kubectl version --client
```

Optional, to verify signatures from your own laptop: install [cosign](https://docs.sigstore.dev/cosign/system_config/installation/).

## Step 2: Fill in your GitHub username

```bash
# once per machine; use the email of your GitHub account so commits link to your profile
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"

cd ~/Personal/projects/secureship
./setup.sh <your-github-username>
```

This replaces the `GITHUB_USER` placeholder everywhere and creates the first commit in both repos.

## Step 3: Create the two GitHub repos

On github.com, create two **public**, **empty** repos (no README, no .gitignore):
`secureship-gitops` and `secureship-app`.

Push the GitOps repo first:

```bash
cd ~/Personal/projects/secureship/secureship-gitops
git remote add origin https://github.com/<you>/secureship-gitops.git
git push -u origin main
```

## Step 4: Let the app pipeline write to the GitOps repo

The app pipeline commits the new image digest into the GitOps repo. It uses an SSH **deploy key**
that can write to `secureship-gitops` and nothing else:

```bash
ssh-keygen -t ed25519 -N "" -C secureship-ci -f /tmp/gitops_key
gh repo deploy-key add /tmp/gitops_key.pub -R <you>/secureship-gitops --allow-write -t secureship-ci
gh secret set GITOPS_DEPLOY_KEY -R <you>/secureship-app < /tmp/gitops_key
rm /tmp/gitops_key /tmp/gitops_key.pub
```

(The `secureship-app` repo must exist first: `gh repo create <you>/secureship-app --public`.)

## Step 5: Push the app and watch the pipeline

```bash
cd ~/Personal/projects/secureship/secureship-app
git remote add origin https://github.com/<you>/secureship-app.git
git push -u origin main
```

Open the **Actions** tab. The pipeline runs:

| Stage | Tool | Fails the build when |
|---|---|---|
| Secret scan | Gitleaks | a credential is found anywhere in git history |
| SAST | Semgrep (python + OWASP Top 10 rules) | a code or workflow security issue is found |
| Unit tests | pytest | a test fails |
| SCA | Trivy fs | a dependency has a HIGH/CRITICAL CVE |
| Image scan | Trivy image | the image has a fixable HIGH/CRITICAL CVE |
| DAST | OWASP ZAP baseline | ZAP raises a FAIL-level alert on the running app |
| Push | GHCR | (main branch only) |
| Sign | Cosign keyless (GitHub OIDC) | (main branch only) |
| SBOM | Syft, attested with Cosign | (main branch only) |
| Promote | commits the digest to `secureship-gitops` | (main branch only) |

When it finishes, check that `secureship-gitops/chart/secureship/values.yaml` now has an `image.digest`.

## Step 6: Make the image public

New GHCR packages are private, and the cluster pulls without credentials.

GitHub profile → **Packages** → `secureship-app` → Package settings → **Change visibility → Public**.

## Step 7: Create the cluster and hand it to Argo CD

```bash
cd ~/Personal/projects/secureship/secureship-gitops
./scripts/bootstrap.sh
```

This starts minikube (4 CPU, 5 GB RAM, Calico so NetworkPolicy is enforced), installs Argo CD,
and applies the root app. Argo CD then installs, in order:

1. **Kyverno** (wave -2): admission controller
2. **Policies** + **kube-prometheus-stack** (wave -1)
3. **secureship** app (wave 0)

Wait about 5 minutes, then:

```bash
kubectl -n argocd get applications      # all should become Synced / Healthy
kubectl -n secureship get pods          # 2 pods Running
```

The bootstrap output prints the port-forward commands and the Argo CD password.

## Step 8: Run the demos (record these for your README and LinkedIn)

Open the app: `kubectl -n secureship port-forward svc/secureship 8081:80`, then `curl localhost:8081`.

**Demo 1: GitOps deploy.** Change the response in `app/main.py`, commit and push. The pipeline
runs, commits a new digest, and Argo CD rolls it out within about 3 minutes. `curl` shows the new version.

**Demo 2: the pipeline blocks bad code.** On a new branch, open a pull request with each of these
(one at a time) and watch the matching job fail:

```bash
echo "requests==2.19.0" >> requirements.txt                    # SCA fails (CVE-2018-18074)
echo "TOKEN = \"ghp_$(openssl rand -hex 18)\"" > app/leak.py   # Gitleaks fails (fake GitHub token)
```

**Demo 3: the cluster refuses unsigned images.**

```bash
kubectl run evil -n secureship --image=nginx:1.27
# Error from server: admission webhook "...kyverno..." denied the request, e.g.:
#   verify-secureship-signature ...  images must be pinned by digest ...
```

**Demo 4: drift is reverted.** `kubectl -n secureship scale deploy secureship --replicas=5`.
Argo CD's self-heal sets it back to 2 within seconds.

**Demo 5: verify the signature yourself** (needs cosign):

```bash
cosign verify ghcr.io/<you>/secureship-app@<digest> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/<you>/secureship-app/'
```

**Demo 6: monitoring.** Generate traffic with
`for i in $(seq 300); do curl -s localhost:8081/ >/dev/null; done`, then open Grafana
(`kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80`) → Dashboards → **SecureShip**.

## Step 9: Polish the GitHub repos

- Screenshots to add to `secureship-app/README.md`: the green pipeline, a failed scan, the Kyverno denial,
  the Argo CD app tree and the Grafana dashboard.
- Pin both repos on your GitHub profile.
- Stop the cluster when not in use: `minikube stop -p secureship`. Delete it: `minikube delete -p secureship`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Argo CD app `secureship` errors with "image.digest is empty" | The app pipeline has not finished on main yet (step 5). |
| `update-gitops` job fails with 403 | The `GITOPS_DEPLOY_KEY` secret is missing, or the deploy key lacks write access (step 4). |
| Pods denied with "no signatures found" or `ImagePullBackOff` | The GHCR package is still private (step 6). |
| Pods denied even though signed | The repo must be named exactly `secureship-app` and the workflow file `ci.yml` on `main`; the policy matches that identity. |
| Laptop runs out of memory | `MEMORY=4g ./scripts/bootstrap.sh`, or delete `argocd/apps/monitoring.yaml` and push. |
| Trivy image scan fails later on a new CVE | That is the gate working: re-run the pipeline (the Dockerfile applies OS patches) or bump the base image. |

## Resume bullets (use once it is running)

- Built a GitOps delivery platform with GitHub Actions, Helm and Argo CD (app-of-apps, self-healing),
  gating every commit on secret scanning (Gitleaks), SAST (Semgrep), SCA and image scanning (Trivy) and DAST (OWASP ZAP).
- Secured the software supply chain with keyless image signing and SBOM attestation (Cosign, Syft, Sigstore),
  deploying by immutable digest only.
- Enforced signature verification and pod hardening at admission with Kyverno CEL policies, covered by
  automated policy tests in CI; added Prometheus/Grafana observability and Calico NetworkPolicies.
