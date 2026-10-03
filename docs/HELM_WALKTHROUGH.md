# 📖 Walkthrough: how this repo deploys ShopFlow to Kubernetes (Helm + ArgoCD)

This guide explains every file in plain English. **No Kubernetes or Helm experience needed.** New terms are explained as they come up. For the application code itself, see the [code walkthrough in shopflow-app](https://github.com/chaithanyareddyk3273/shopflow-app/blob/main/docs/CODE_WALKTHROUGH.md).

---

## 1. What this repo is for

Kubernetes is told what to run through **YAML files** ("manifests"): "run 2 copies of orders-api", "give Postgres 1 GB of storage", and so on.

Writing those by hand for every service and environment means lots of copy-paste. **Helm** fixes that: you write **templates** once and fill them in with **values**. A set of templates is called a **chart**.

```
templates (how)  +  values (what)  ──helm──▶  Kubernetes YAML  ──▶  cluster
```

In GitOps, **this repo is the single source of truth**. Whatever is merged here is what runs in the cluster. **ArgoCD** makes that happen automatically (see [section 9](#9-argocd-and-the-pipeline)).

---

## 2. The files

```
shopflow-gitops/
├── charts/shopflow/
│   ├── Chart.yaml              name + version of the chart
│   ├── values.yaml             ⭐ the settings: images, replicas, memory, ...
│   └── templates/
│       ├── services.yaml       ⭐ Deployment + Service for each microservice
│       ├── postgres.yaml       the database
│       ├── rabbitmq.yaml       the message broker
│       ├── secrets.yaml        passwords (plain Secret, or encrypted SealedSecret)
│       ├── monitoring.yaml     Prometheus ServiceMonitor + alert rules
│       ├── hpa.yaml            autoscalers
│       ├── networkpolicies.yaml  pod-to-pod firewall
│       ├── rollouts-analysis.yaml  canary health check
│       ├── _helpers.tpl        small reusable snippets (labels, security settings)
│       └── NOTES.txt           message printed after `helm install`
├── environments/
│   ├── local/values.yaml       your laptop (images built locally)
│   ├── dev/values.yaml         dev: image versions written by CI automatically
│   └── prod/values.yaml        prod: image versions changed only by a reviewed PR
├── argocd/
│   ├── root.yaml               the "app of apps" (applied once, by hand)
│   └── apps/                   one ArgoCD Application per environment
├── .github/workflows/
│   ├── validate.yml            checks the chart on every pull request
│   └── promote.yml             opens the dev → prod promotion pull request
├── platform/dashboards/        Grafana dashboard as code (+ kustomization)
├── scripts/argocd-up.sh        installs ArgoCD in the local cluster
├── scripts/seal-credentials.sh encrypts new passwords for one environment
├── scripts/apply-credentials.sh changes passwords in running databases (no data loss)
└── kind/kind-config.yaml       defines the local Kubernetes cluster
```

**Reading order:** `values.yaml` → `templates/services.yaml` → `environments/` → `argocd/apps/shopflow-dev.yaml` → `postgres.yaml`.

---

## 3. `values.yaml`: the settings

```yaml
services:
  orders-api:
    image:
      repository: shopflow/orders-api
      tag: dev
    replicas: 2
    database: orders        # this service gets DATABASE_URL pointing at the "orders" database
    rabbitmq: true          # this service gets RABBITMQ_URL
    env:
      INVENTORY_URL: http://inventory-svc:8000
    resources:
      requests: { cpu: 50m, memory: 96Mi }
      limits: { memory: 256Mi }
```

| Setting | Meaning |
|---|---|
| `image` | Which container image to run (`repository:tag`) |
| `replicas` | How many copies (pods) to run. More copies = more capacity, and one can crash without downtime. |
| `database` | Which Postgres database this service owns. Empty means it doesn't use one. |
| `rabbitmq` | Whether it needs the RabbitMQ connection |
| `env` | Extra settings passed as environment variables |
| `resources.requests` | What Kubernetes **reserves** for the pod. `50m` CPU = 5% of one CPU core; `96Mi` = 96 MB. |
| `resources.limits` | The **maximum** it may use. If it goes over the memory limit, the pod is restarted. |

**Why there's no CPU limit:** a CPU limit *slows the app down* (throttling) even when the machine has spare CPU. The memory limit stays, because memory can't be "slowed down" and one leaky pod could starve the others.

---

## 4. `templates/services.yaml`: one template for all three services

It starts with a **loop**:

```yaml
{{- range $name, $svc := .Values.services }}
```

That means "for each entry under `services:` in values.yaml, create the following." So this one file produces a **Deployment** and a **Service** for orders-api, inventory-svc *and* notifier. Anything inside `{{ }}` is filled in by Helm; everything else is plain Kubernetes YAML.

### The Deployment ("keep N copies of this pod running")

| Part | What it does |
|---|---|
| `replicas: {{ $svc.replicas }}` | Number of pods, taken from values.yaml |
| `selector` / `labels` | How Kubernetes knows which pods belong to this Deployment |
| `prometheus.io/scrape: "true"` | Tells Prometheus to collect this pod's `/metrics` (used in Phase 3) |
| `checksum/credentials` | A fingerprint of the passwords. If a password changes, the fingerprint changes, and Kubernetes restarts the pods so they pick up the new one. |
| `securityContext` | **Security:** never run as root, read-only filesystem, no extra Linux privileges |
| `automountServiceAccountToken: false` | The app never talks to the Kubernetes API, so it gets no credentials for it |

**How the database password reaches the app without being written into the config:**

```yaml
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:                      # 1. read the password from the Secret
      name: shopflow-credentials
      key: postgres-password
- name: DATABASE_URL                   # 2. Kubernetes replaces $(POSTGRES_PASSWORD) at startup
  value: "postgresql://shopflow:$(POSTGRES_PASSWORD)@postgres:5432/orders"
```

**The three health checks (probes):**

| Probe | Checks | If it fails |
|---|---|---|
| `startupProbe` → `/healthz` | "Has the app finished starting?" Allows up to 2 minutes, because services wait for Postgres on first start. | Keeps waiting (up to 2 min), then restarts |
| `livenessProbe` → `/healthz` | "Is it still alive?" | Restarts the pod |
| `readinessProbe` → `/readyz` | "Can it handle requests?" (database/RabbitMQ reachable) | Stops sending it traffic, without a restart |

### The Service ("a stable address")

Pods come and go and their IP addresses change. A **Service** gives them one permanent name. That's why orders-api can always reach inventory at `http://inventory-svc:8000`, and requests are spread across all of inventory's pods.

---

## 5. `postgres.yaml` and `rabbitmq.yaml`: the data stores

Both use a **StatefulSet** instead of a Deployment. A StatefulSet is for things that store data: each pod gets a **stable name** (`postgres-0`) and **its own disk** (`volumeClaimTemplates`) that survives restarts.

`postgres.yaml` also has a **ConfigMap** with an `init.sql` script. It's generated by looping over the services, so it creates one database per service:

```sql
CREATE DATABASE inventory;
CREATE DATABASE orders;
```

**For production** these would be managed services instead (Amazon RDS for Postgres, Amazon MQ for RabbitMQ), so AWS handles backups, failover and upgrades.

---

## 6. `secrets.yaml`: passwords

A Kubernetes **Secret** stores sensitive values. ⚠️ The values here are **dev-only placeholders** (`shopflow-dev`). Real passwords must never be committed to Git. Phase 3 replaces this with **Sealed Secrets** or **External Secrets**, which keep the real secret encrypted or in AWS Secrets Manager.

---

## 7. `_helpers.tpl`: reusable snippets

Small named templates used by every file, so labels and security settings are written once:

| Helper | Gives |
|---|---|
| `shopflow.labels` | Standard labels (name, version, "managed by Helm") on every resource |
| `shopflow.selectorLabels` | The labels used to match pods; these must never change after the first install |
| `shopflow.containerSecurityContext` | No privilege escalation, read-only filesystem, all Linux capabilities dropped |

---

## 8. `environments/`: one chart, many environments

`charts/shopflow/values.yaml` holds the defaults. Each environment overrides only what's different:

| Environment | Namespace | Images come from | Replicas | Who changes it |
|---|---|---|---|---|
| `local` | `shopflow` | built on your laptop (`imagePullPolicy: Never`) | 1 | you, via `kind-up.sh` |
| `dev` | `shopflow-dev` | GitHub Container Registry | 1 | **CI, automatically**, after every green build |
| `prod` | `shopflow-prod` | GitHub Container Registry | 2 (APIs) | **only a merged promotion PR** |

```yaml
# environments/prod/values.yaml (excerpt)
services:
  orders-api:
    replicas: 2          # 2 copies: one pod can fail or be replaced with no downtime
    image:
      repository: ghcr.io/chaithanyareddyk3273/shopflow-orders-api
      tag: sha-1a2b3c4   # exactly which commit of the code runs in prod
```

The tag is `sha-` plus the Git commit of shopflow-app, never `latest`. You can always tell exactly which code is running, and going back means setting the previous tag.

---

## 9. ArgoCD and the pipeline

**ArgoCD** is a program that runs *inside* the Kubernetes cluster. Every few minutes it compares **what Git says** with **what's running**, and if they differ, it changes the cluster to match Git ("sync").

### An ArgoCD Application (`argocd/apps/shopflow-dev.yaml`)
```yaml
source:
  repoURL: https://github.com/chaithanyareddyk3273/shopflow-gitops.git
  path: charts/shopflow                          # the chart...
  helm:
    valueFiles: [../../environments/dev/values.yaml]   # ...filled in with dev's values
destination:
  namespace: shopflow-dev                        # ...deployed here
syncPolicy:
  automated:
    prune: true      # something deleted from Git → deleted from the cluster
    selfHeal: true   # someone runs `kubectl edit` by hand → ArgoCD puts it back
```

### "App of apps" (`argocd/root.yaml`)
Instead of applying each Application by hand, we apply **one** Application (`root.yaml`) whose job is to deploy everything in `argocd/apps/`. Adding a new environment is then just adding a file and merging it.

### The full journey of a code change
1. A developer pushes to **shopflow-app** `main`.
2. **CI** tests the code, builds the images, scans them with Trivy, and pushes them to GitHub Container Registry as `sha-abc1234`.
3. CI **commits** `tag: sha-abc1234` into `environments/dev/values.yaml` in this repo.
4. **ArgoCD** notices the commit and updates `shopflow-dev`. Kubernetes replaces the pods one by one, with no downtime.
5. When dev looks good, someone runs **"Promote dev → prod"** in this repo's Actions tab. It opens a **pull request** changing prod's tags to dev's.
6. A human reviews and **merges** it, and ArgoCD updates `shopflow-prod`.

**Rollback:** revert the PR (or the CI commit). ArgoCD sees Git go back and deploys the previous version.

### Why CI doesn't deploy directly
CI has **no Kubernetes credentials at all**. It can only change Git. If CI were ever compromised, the attacker couldn't touch the cluster. Every change is also a Git commit, so you always know who changed what, when, and why.

### `validate.yml`: a safety net
Because ArgoCD deploys whatever is on `main`, a broken chart would break dev and prod. So every pull request runs `helm lint` and **kubeconform** (which checks the generated YAML against Kubernetes' official schemas) for all three environments, plus the ArgoCD files.

---

## 10. Production features (Phase 3)

Five features turn the demo into something you'd run for real. Each one is **switched off in `charts/shopflow/values.yaml`** and switched on per environment, so it reaches **dev first** and **prod only through a reviewed PR**, the same as code.

They rely on four **platform tools**, installed once for the whole cluster by ArgoCD (`argocd/apps/platform-*.yaml`):

| Platform app | What it is | Needed by |
|---|---|---|
| `platform-monitoring` | **Prometheus** (collects metrics), **Grafana** (dashboards), **Alertmanager** (alerts) | monitoring, canary |
| `platform-metrics-server` | Measures each pod's CPU and memory | autoscaling |
| `platform-sealed-secrets` | Decrypts encrypted secrets inside the cluster | secrets |
| `platform-argo-rollouts` | Runs canary deployments | canary |
| `platform-dashboards` | The ShopFlow Grafana dashboard, from `platform/dashboards/` | monitoring |

### 10.1 Monitoring: `monitoring.enabled` → `templates/monitoring.yaml`
- A **ServiceMonitor** tells Prometheus: "every 15 seconds, read `/metrics` from orders-api, inventory-svc and notifier".
- A **PrometheusRule** holds 4 **alerts**: a service is down for 2 minutes; more than 5% of requests fail; 95% of requests take longer than 500 ms; order events were lost.
- The **Grafana dashboard** (`platform/dashboards/shopflow.json`) shows traffic, errors and latency per service (the "RED" method: Rate, Errors, Duration), plus orders, stock reservations and notifications. Pick the environment at the top.

```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80    # http://localhost:3000  (admin / shopflow-demo)
```

### 10.2 Autoscaling: `services.<name>.autoscaling` → `templates/hpa.yaml`
A **HorizontalPodAutoscaler** checks CPU every 15 seconds. If the pods use more than **70% of the CPU they requested**, it adds pods (up to `maxReplicas`); when load drops it waits 2 minutes, then removes them. With autoscaling on, the chart **stops setting `replicas`**, otherwise ArgoCD and the autoscaler would fight over it.

> Tested: 4 load-generator workers took orders-api from **2 → 5 pods** and inventory-svc from **2 → 4** within 30 seconds.

### 10.3 Network security: `networkPolicies.enabled` → `templates/networkpolicies.yaml`
By default every pod can talk to every other pod. These rules **block everything**, then open only what's needed:

| From | orders-api | inventory-svc | postgres | rabbitmq |
|---|---|---|---|---|
| anywhere (public API) | ✅ | 🚫 | 🚫 | 🚫 |
| orders-api | | ✅ | ✅ | ✅ |
| inventory-svc | | | ✅ | 🚫 |
| notifier | | 🚫 | 🚫 | ✅ |
| Prometheus | ✅ /metrics | ✅ /metrics | | |

> Tested: from an unknown pod, only orders-api answered; from the notifier, RabbitMQ answered but **Postgres and inventory-svc were blocked**.

### 10.4 Secrets: `sealedSecrets` → `templates/secrets.yaml`
Passwords can't go in Git in plain text. **Sealed Secrets** solves this with public-key encryption:
1. `scripts/seal-credentials.sh shopflow-dev` creates random passwords and **encrypts** them with the cluster's **public** key. The plain passwords are never shown or saved.
2. The encrypted text (`AgB…`) goes in `environments/dev/values.yaml`. It's safe in a public repo: only the controller inside the cluster has the **private** key, and the result only decrypts in that exact namespace.
3. In the cluster, the controller turns the **SealedSecret** into a normal Secret, which the pods use as before.

⚠️ **Changing passwords on a running environment.** Postgres and RabbitMQ only read their password when their data volume is **first created**, so after the Secret changes they still expect the old one. `scripts/apply-credentials.sh shopflow-dev` changes the password **inside** the running Postgres (`ALTER USER`) and RabbitMQ (`rabbitmqctl change_password`), **with no data lost**, then restarts the services. The passwords go from the Secret to the databases through stdin, so they're never printed or written to disk. (With a managed database like Amazon RDS, AWS Secrets Manager can rotate them automatically instead.)

⚠️ **The encrypted values belong to one cluster.** A new cluster has a new key, so re-run the script there (or back up and restore the controller's key).

### 10.5 Canary deployments: `services.<name>.canary` → Argo Rollouts
With `canary.enabled`, orders-api becomes a **Rollout** instead of a Deployment. A new version then goes out like this:

```
new version ──▶ 50% of pods ──▶ wait 30 s ──▶ Prometheus check ×4 ──▶ 100% ✅
                                                     │
                                       success rate < 95%
                                                     ▼
                                     ABORT: all pods back to the old version ↩
```

The check (`templates/rollouts-analysis.yaml`) asks Prometheus: *"of the requests to `POST /orders` handled by the **new** pods in the last minute, what share succeeded?"* The new pods are identified by the `rollouts-pod-template-hash` label, which the ServiceMonitor copies onto every metric.

> Tested with real traffic:
> - **Good version:** 4/4 checks passed and it was promoted to 100% automatically, in about 100 seconds.
> - **Broken version** (`FAULT_INJECTION_RATE=0.5`: half of all orders fail): two checks measured **48%** and **46%** success, the rollout was **aborted 78 seconds** after the deploy, and all 5 pods went **back to the previous version automatically**: `RolloutAborted: Metric "success-rate" assessed Failed due to failed (2) > failureLimit (1)`.
> - The first check of a new version returns 1 ("no data yet counts as healthy") until Prometheus has scraped the new pods twice, which is why the analysis takes 4 measurements and allows only 1 failure.

**In GitOps terms:** after an automatic abort, Git still describes the bad version, and ArgoCD shows the app as **Degraded**. You fix it the GitOps way: **revert the commit or PR** that introduced the bad version.

---

## 11. Try it yourself

```bash
# Check the chart for mistakes
helm lint charts/shopflow -f environments/dev/values.yaml

# See the exact Kubernetes YAML Helm produces, without installing anything
helm template shopflow charts/shopflow -f environments/dev/values.yaml

# Install the "local" environment by hand (normally done by shopflow-app/scripts/kind-up.sh)
helm upgrade --install shopflow charts/shopflow -n shopflow --create-namespace -f environments/local/values.yaml

# Install ArgoCD in your kind cluster; it then deploys dev and prod by itself
./scripts/argocd-up.sh
kubectl get applications -n argocd              # Synced + Healthy = matches Git

# Look at what's running
kubectl get pods -n shopflow-dev
kubectl describe pod -n shopflow <pod-name>     # details + recent events (great for debugging)
kubectl logs -n shopflow deploy/orders-api      # the app's log output
```

---

## 📚 Glossary

| Term | Meaning |
|---|---|
| **Manifest** | A YAML file describing something Kubernetes should run |
| **Helm chart** | A package of templates that produce manifests |
| **Values** | The settings that fill in the templates |
| **Pod** | The smallest thing Kubernetes runs: one container (here) plus its settings |
| **Deployment** | "Keep N identical pods running", for stateless apps |
| **StatefulSet** | Like a Deployment, but each pod keeps its name and its own disk, for databases |
| **Service** | A stable name and address in front of a group of pods |
| **ConfigMap / Secret** | Configuration given to pods; a Secret is for sensitive values |
| **Probe** | A health check Kubernetes runs against a pod |
| **Namespace** | A folder-like grouping of resources (`shopflow`) |
| **kind** | A real Kubernetes cluster running inside Docker on your laptop |
| **GitOps** | Git is the source of truth for what runs; a tool (ArgoCD) makes the cluster match Git |
| **ArgoCD Application** | Tells ArgoCD: "deploy this folder of this Git repo into this namespace" |
| **Sync / self-heal / prune** | Make the cluster match Git / undo manual changes / delete what was removed from Git |
| **Promotion** | Moving a version that's tested in one environment (dev) to the next (prod) |
| **Image tag** | The version label of a container image; here `sha-<commit>` |
| **GHCR** | GitHub Container Registry, where CI stores the built images |
| **Prometheus / Grafana / Alertmanager** | Collects metrics / shows them as dashboards / sends alerts |
| **ServiceMonitor / PrometheusRule** | Tell Prometheus what to scrape / which alerts to evaluate |
| **HPA (HorizontalPodAutoscaler)** | Adds or removes pods based on CPU use |
| **NetworkPolicy** | A firewall rule between pods |
| **SealedSecret** | A Secret encrypted with the cluster's public key, safe to store in Git |
| **Canary / Rollout** | Releasing a new version to part of the traffic first; Argo Rollouts' replacement for a Deployment |
| **AnalysisTemplate** | The Prometheus check that decides whether a canary is promoted or rolled back |
