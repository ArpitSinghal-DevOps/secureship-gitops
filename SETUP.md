# SecureShip: step-by-step setup

Everything is free: public GitHub repos get free Actions minutes and free GHCR storage,
Sigstore signing is free, and the cluster runs locally on minikube.

**Only Docker (and git) are needed on the laptop.** Every other CLI runs in a container:

| Wrapper (in `secureship-gitops/tools/`) | Runs | How |
|---|---|---|
| `tools/k ...` | kubectl | the kubectl binary inside the minikube node container (`docker exec`) |
| `tools/run gh ...`, `tools/run git ...`, `tools/run cosign ...` | gh, git, cosign v3, yq | toolbox image built from `tools/Dockerfile` |
| `tools/minikube ...` | minikube | toolbox image, driving Docker through its socket |
| `tools/node-ip` | prints the minikube node IP | `docker inspect` |
| `tools/monitoring up\|down\|status\|purge` | Prometheus + Grafana | two containers on the minikube Docker network |

The toolbox keeps your GitHub login in the Docker volume `secureship-toolbox-home`.
Run the wrappers from inside `secureship-gitops/` (or give their path, e.g. `../secureship-gitops/tools/run`).

```
secureship/
├── setup.sh             one-time: fills in your GitHub username, runs git init
├── secureship-app/      FastAPI app + secure CI pipeline              -> GitHub repo #1
└── secureship-gitops/   Helm chart, Argo CD, Kyverno, tools, this guide -> GitHub repo #2
```

---

## Step 1: GitHub login (once, inside the toolbox)

```bash
cd ~/Personal/projects/secureship/secureship-gitops
tools/run gh auth login -h github.com -p https -w -s workflow
tools/run gh auth setup-git
tools/run git config --global user.name  "Your Name"
tools/run git config --global user.email "you@example.com"   # your GitHub email
```

## Step 2: Fill in your GitHub username

```bash
cd ~/Personal/projects/secureship
./setup.sh <your-github-username>
```

This replaces the `GITHUB_USER` placeholder and creates the first commit in both repos.

## Step 3: Create the repos and the deploy key

The app pipeline commits each new image digest into the GitOps repo, using an SSH **deploy key**
that can write to `secureship-gitops` and nothing else.

```bash
cd ~/Personal/projects/secureship/secureship-gitops
U=<your-github-username>
tools/run gh repo create $U/secureship-gitops --public --source . --remote origin --push
tools/run sh -c 'cd ../secureship-app && gh repo create '$U'/secureship-app --public --source . --remote origin'

tools/run sh -c 'ssh-keygen -q -t ed25519 -N "" -C secureship-ci -f /tmp/k &&
  gh repo deploy-key add /tmp/k.pub -R '$U'/secureship-gitops --allow-write -t secureship-ci &&
  gh secret set GITOPS_DEPLOY_KEY -R '$U'/secureship-app < /tmp/k'
```

(The key exists only inside that short-lived container and in GitHub.)

## Step 4: Push the app and watch the pipeline

```bash
cd ~/Personal/projects/secureship/secureship-app
../secureship-gitops/tools/run git push -u origin main
../secureship-gitops/tools/run gh run watch -R $U/secureship-app
```

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
| Provenance | SLSA build provenance (GitHub artifact attestation), then signature, SBOM and provenance re-verified | (main branch only) |
| Promote | commits the digest to `secureship-gitops` | (main branch only) |

The image package inherits the public visibility of the repo (the pipeline sets the
`org.opencontainers.image.source` label). If it ever shows as private, open
GitHub profile → Packages → `secureship-app` → Package settings → Change visibility → Public.

## Step 5: Create the cluster and hand it to Argo CD

```bash
cd ~/Personal/projects/secureship/secureship-gitops
tools/run git pull            # picks up the digest commit from the pipeline
./scripts/bootstrap.sh
```

This creates (or restarts) the minikube container (4 CPU, 5 GB RAM, Calico so NetworkPolicy is
enforced), installs Argo CD, and applies the root app. Argo CD then installs, in order:

1. **Kyverno** (wave -2): admission controller
2. **Policies** (wave -1)
3. **secureship** app (wave 0)

After about 5 minutes:

```bash
tools/k -n argocd get applications      # all Synced / Healthy
tools/k -n secureship get pods          # 2 pods Running
```

The bootstrap output prints the Argo CD password and the URLs.

**Opening things in the browser.** Port-forwards run inside the node container, so bind them to
`0.0.0.0` and open the node IP (`tools/node-ip`, usually `192.168.49.2`):

```bash
tools/k -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:443   # https://192.168.49.2:8080
tools/k -n secureship port-forward --address 0.0.0.0 svc/secureship 8081:80   # http://192.168.49.2:8081
```

## Step 6: Run the demos (record these for your README and LinkedIn)

**Demo 1: GitOps deploy.** Change the response in `app/main.py`, commit, and push with
`../secureship-gitops/tools/run git push`. The pipeline runs, commits a new digest, and Argo CD rolls
it out within about 3 minutes. Open the app URL to see the new response.

**Branch protection.** `main` of `secureship-app` requires a pull request with all five scan/test/build
checks green (no force-push, no deletion). As the repo admin you can still push directly; GitHub then
reports "bypassed rule violations". `secureship-gitops` only blocks force-push and deletion, because the
pipeline commits the digest there directly with its deploy key.

**Demo 2: the pipeline blocks bad code.** On a new branch, open a pull request with each of these
(one at a time) and watch the matching job fail:

```bash
echo "python-multipart==0.0.6" >> requirements.txt              # SCA fails (CVE-2024-24762, HIGH)
echo "TOKEN = \"ghp_$(openssl rand -hex 18)\"" > app/leak.py   # Gitleaks fails (fake GitHub token)
```

**Demo 3: the cluster refuses unsigned images.** This pod follows every hardening rule
(digest-pinned, limits, non-root, read-only), so the only reason for rejection is the signature:

```bash
I=nginx@sha256:6784fb0834aa7dbbe12e3d7471e69c290df3e6ba810dc38b34ae33d3c1c05f7d   # nginx:1.27
tools/k run evil -n secureship --image=$I --overrides='{"spec":{"securityContext":{"runAsNonRoot":true},
  "containers":[{"name":"c","image":"'$I'","securityContext":{"allowPrivilegeEscalation":false,
  "readOnlyRootFilesystem":true},"resources":{"limits":{"cpu":"100m","memory":"64Mi"}}}]}}'
# denied: Policy verify-secureship-signature failed: image is not signed by the secureship-app CI pipeline
```

And the simple version, `tools/k run evil -n secureship --image=nginx:1.27`, is denied by the pod-hardening policy.

**Demo 4: drift is reverted.** `tools/k -n secureship scale deploy secureship --replicas=5`.
Argo CD's self-heal sets it back to 2 in about 15 seconds.

**Demo 5: verify the signature yourself:**

```bash
tools/run cosign verify ghcr.io/<you-lowercase>/secureship-app@<digest> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/<you>/secureship-app/'
```

**Demo 6: monitoring.** Prometheus and Grafana run as two Docker containers next to the minikube
container (about 250 MB RAM together, versus 1.5 GB+ for kube-prometheus-stack inside the cluster):

```bash
tools/monitoring up        # start; prints the URLs
tools/monitoring status    # containers + scrape targets (both pods should be "up")
tools/monitoring down      # stop (metrics kept in monitoring/.data)
tools/monitoring purge     # stop and delete data, copied token and Grafana password
```

- Grafana: http://localhost:3000, user `admin`, password in `monitoring/.secrets/grafana-admin`. The
  **SecureShip** dashboard (request rate, errors, p95 latency, restarts) opens as the home page.
- Prometheus: http://localhost:9090/targets
- How it scrapes: the chart creates a read-only ServiceAccount `secureship-metrics-reader` (list pods and
  `pods/proxy` in the `secureship` namespace only). `tools/monitoring up` copies its token and the cluster
  CA into `monitoring/.secrets/` (git-ignored), and Prometheus reaches each pod's `/metrics` through the
  API server proxy. Both containers run as your user, with all capabilities dropped and memory limits,
  and are bound to `127.0.0.1` only.
- Run `tools/monitoring up` again after a new cluster or `purge`. `docker stop secureship` does not stop
  them, so run `tools/monitoring down` too to free the RAM.

(The heavier in-cluster alternative is kept in `argocd/optional/monitoring.yaml`.)

## Step 7: Polish the GitHub repos

- Screenshots live in `secureship-app/docs/img/` (green pipeline, both demo PRs, Argo CD trees) and are
  shown in the app README's "See it work" section. Retake them after big UI changes.
- Pin both repos on your GitHub profile.
- Stop everything when not in use: `tools/monitoring down; docker stop secureship`.
  Start again: `./scripts/bootstrap.sh && tools/monitoring up`.
- Delete everything: `docker rm -f secureship && docker volume rm secureship && docker network rm secureship`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Argo CD app `secureship` errors with "image.digest is empty" | The app pipeline has not finished on main yet (step 4). |
| `update-gitops` job fails with a permission error | The `GITOPS_DEPLOY_KEY` secret is missing, or the deploy key lacks write access (step 3). |
| Pods denied with "no signatures found" or `ImagePullBackOff` | The GHCR package is private (see step 4). |
| Pods denied with "required predicate type https://spdx.dev/Document not found" | The image was signed but its SBOM step did not finish: re-run the pipeline. |
| Pods denied even though signed | The repo must be named exactly `secureship-app` and the workflow `ci.yml` on `main`; the policy matches that identity. |
| `tools/k` hangs or "TLS handshake timeout" | The laptop is out of RAM: close heavy apps, keep monitoring off, or `MEMORY=4g ./scripts/bootstrap.sh` for a new cluster. |
| Trivy image scan fails later on a new CVE | That is the gate working: re-run the pipeline (the Dockerfile applies OS patches) or bump the base image. |

## Resume bullets

- Built a GitOps delivery platform with GitHub Actions, Helm and Argo CD (app-of-apps, self-healing),
  gating every commit on secret scanning (Gitleaks), SAST (Semgrep), SCA and image scanning (Trivy) and DAST (OWASP ZAP).
- Secured the software supply chain with keyless image signing, SBOM attestation and SLSA build provenance
  (Cosign, Syft, Sigstore, GitHub artifact attestations), deploying by immutable digest only.
- Enforced signature and SBOM-attestation verification and pod hardening at admission with Kyverno CEL policies
  (ImageValidatingPolicy, ValidatingPolicy) across app, init and ephemeral containers, closing an init-container
  bypass; covered by automated policy tests in CI; default-deny Calico NetworkPolicies.
- Containerised the entire operator toolchain (kubectl, minikube, gh, cosign) so the platform runs with only Docker on the host.
