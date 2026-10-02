# 📖 Walkthrough: how this repo deploys ShopFlow to Kubernetes

This guide explains every file in plain English. **No Kubernetes or Helm experience needed.** New terms are explained as they come up. For the application code itself, see the [code walkthrough in shopflow-app](https://github.com/chaithanyareddyk3273/shopflow-app/blob/main/docs/CODE_WALKTHROUGH.md).

---

## 1. What this repo is for

Kubernetes is told what to run through **YAML files** ("manifests"): "run 2 copies of orders-api", "give Postgres 1 GB of storage", and so on.

Writing those by hand for every service and environment means lots of copy-paste. **Helm** fixes that: you write **templates** once and fill them in with **values**. A set of templates is called a **chart**.

```
templates (how)  +  values (what)  ──helm──▶  Kubernetes YAML  ──▶  cluster
```

In GitOps, **this repo is the single source of truth**. Whatever is merged here is what should run in the cluster. (In Phase 2, ArgoCD will apply it automatically.)

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
│       ├── secrets.yaml        passwords
│       ├── _helpers.tpl        small reusable snippets (labels, security settings)
│       └── NOTES.txt           message printed after `helm install`
├── environments/
│   └── dev/values.yaml         overrides for the local kind cluster
└── kind/kind-config.yaml       defines the local Kubernetes cluster
```

**Reading order:** `values.yaml` → `templates/services.yaml` → `environments/dev/values.yaml` → `postgres.yaml`.

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

```yaml
# environments/dev/values.yaml (local laptop)
imagePullPolicy: Never      # images are built locally and loaded into kind, never downloaded
services:
  orders-api:
    replicas: 1             # 1 copy is enough on a laptop
```

Phase 2 adds `environments/prod/values.yaml`: more replicas, and images from a real registry.

---

## 9. Try it yourself

```bash
# Check the chart for mistakes
helm lint charts/shopflow -f environments/dev/values.yaml

# See the exact Kubernetes YAML Helm produces, without installing anything
helm template shopflow charts/shopflow -f environments/dev/values.yaml

# Install it (normally done by shopflow-app/scripts/kind-up.sh)
helm upgrade --install shopflow charts/shopflow -n shopflow --create-namespace -f environments/dev/values.yaml

# Look at what's running
kubectl get pods -n shopflow
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
