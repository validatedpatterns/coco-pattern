# CoCo Pattern — AI Coding Assistant Guidance

This is a [Validated Pattern](https://validatedpatterns.io/) for deploying confidential containers (CoCo) on OpenShift.
This file provides rules and context for any AI coding assistant working in this repository.

## Critical Rules

- **DO NOT** edit anything under `/common/`. It is a read-only Git subtree from the upstream validated patterns framework.
- **DO NOT** commit secrets, credentials, or private keys. `values-secret.yaml.template` is a template only.
- **DO NOT** use Kustomize. This project uses Helm exclusively.
- **DO NOT** create charts with `apiVersion: v1`. Use `apiVersion: v2` (Helm 3+).
- **DO NOT** place cloud-provider-specific logic in chart templates. Use `/overrides/` via `sharedValueFiles` instead.
- **DO NOT** hardcode secrets in templates. Use External Secrets Operator with vault paths (see `charts/hub/trustee/templates/dynamic-eso.yaml` for reference).

## Feature Development Precedence Order

Use the **first** approach that fits your requirement:

1. **Helm charts** — Declarative Kubernetes resources in `/charts/`, deployed by ArgoCD. Preferred for installing operators, configuring CRDs, and creating Kubernetes resources.
2. **ACM policies** — Red Hat Advanced Cluster Management policies for propagating configuration from hub to spoke clusters and enforcing multi-cluster governance. Reference: `validatedpatterns/sandboxed-policies-chart`.
3. **Imperative framework (Ansible)** — Playbooks in `/ansible/`, executed as Kubernetes Jobs on a 10-minute schedule. **Must be idempotent.** Use for API calls, runtime data lookups, and multi-step orchestration that cannot be expressed declaratively. Register playbooks in `clusterGroup.imperative.jobs` as an ordered list.
4. **Out-of-band scripts** — `/scripts/` or `/rhdp/`. Last resort for one-time setup or local development tooling. These are not managed by GitOps.

## Project Structure

```text
├── ansible/                        # Ansible playbooks (imperative jobs)
├── charts/
│   ├── all/
│   │   └── letsencrypt/            # Shared across cluster groups
│   ├── coco-supported/
│   │   ├── baremetal/              # Bare-metal TDX configuration
│   │   ├── hello-openshift/        # Sample workloads
│   │   ├── kbs-access/             # KBS access verification workload
│   │   └── sandbox/                # Sandboxed containers runtime
│   └── hub/
│       ├── lvm-storage/            # LVM storage for bare-metal
│       ├── sandbox-policies/       # ACM policies (hub → spoke)
│       └── trustee/                # Trustee / KBS
├── common/                         # READ-ONLY — upstream framework subtree
├── overrides/                      # Cloud-provider value overrides
│   ├── values-AWS.yaml
│   ├── values-Azure.yaml
│   └── values-IBMCloud.yaml
├── rhdp/                           # Red Hat Demo Platform tooling
├── scripts/                        # Utility scripts
├── values-global.yaml              # Global configuration
├── values-simple.yaml              # Cluster group: simple
├── values-baremetal.yaml           # Cluster group: baremetal
├── values-trusted-hub.yaml         # Cluster group: trusted-hub
├── values-spoke.yaml               # Cluster group: spoke
└── values-secret.yaml.template     # Secrets template (never commit filled-in copy)
```

## Companion Chart Repositories

These charts are published independently and consumed from the `charts.validatedpatterns.io` Helm registry via `chart:` + `chartVersion:` in the values files.

| Chart Name | Repository | Purpose |
|---|---|---|
| `trustee` | `validatedpatterns/trustee-chart` | Trustee / KBS configuration |
| `sandboxed-policies` | `validatedpatterns/sandboxed-policies-chart` | ACM policies hub → spoke |
| `sandboxed-containers` | `validatedpatterns/sandboxed-containers-chart` | Sandboxed runtime on spoke |

Changes to companion charts require a release (Git tag) before the pattern can consume them. Update the `chartVersion:` field in the values files to pick up new releases.

## Cluster Groups

Set via `main.clusterGroupName` in `values-global.yaml`.

| Cluster Group | Values File | Role | Description |
|---|---|---|---|
| `simple` | `values-simple.yaml` | Hub (single cluster) | All components on one Azure cluster |
| `baremetal` | `values-baremetal.yaml` | Hub (single cluster) | TDX/SNP + LVM storage on bare metal |
| `baremetal-gpu` | `values-baremetal-gpu.yaml` | Hub (single cluster) | Bare metal + NVIDIA H100 GPU support |
| `trusted-hub` | `values-trusted-hub.yaml` | Multi-cluster hub | Trustee + ACM policies |
| `spoke` | `values-spoke.yaml` | Multi-cluster spoke | Sandbox runtime + workloads |

## Values File Hierarchy

Merge order (last wins):

1. Chart defaults (`charts/<group>/<chart>/values.yaml`)
2. `values-global.yaml`
3. `values-<clustergroup>.yaml`
4. `/overrides/values-{{ clusterPlatform }}.yaml` (via `sharedValueFiles`)
5. `values-secret.yaml` (runtime only, never committed)

Key conventions:

- Global settings go under the `global:` key in `values-global.yaml`.
- Subscriptions go under `clusterGroup.subscriptions:` in the cluster group values file.
- Applications go under `clusterGroup.applications:` in the cluster group values file.
- Local charts use `path:` (e.g., `path: charts/hub/trustee`). Shared framework charts use `chart:` + `chartVersion:`.
- Imperative jobs go under `clusterGroup.imperative.jobs:` as an **ordered list** (not a hash — hashes lose ordering in Helm).

## Helm Chart Conventions

- Use `apiVersion: v2`. Place charts in `charts/<cluster-group>/<chart-name>/`.
- Use ArgoCD sync-wave annotations to control deployment ordering.
- Use `ExternalSecret` resources to pull secrets from vault. Reference: `charts/hub/trustee/templates/dynamic-eso.yaml`.
- Use `.Values.global.clusterPlatform` for platform-conditional logic only when overrides files are insufficient.
- Reference patterns:
  - ESO integration: `charts/hub/trustee/templates/dynamic-eso.yaml`
  - Template helpers: `charts/coco-supported/hello-openshift/templates/_helpers.tpl`

## Ansible Playbook Conventions

- Place playbooks in `/ansible/`. They **must be idempotent**.
- Use `connection: local`, `hosts: localhost`, `become: false`.
- Use `kubernetes.core.k8s` and `kubernetes.core.k8s_info` modules for cluster interaction.
- Register playbooks in the cluster group values file under `clusterGroup.imperative.jobs` with `name`, `playbook`, `verbosity`, and `timeout` fields.

## Git Workflow

- **Fork-first**: ArgoCD reconciles against your fork. Clone and push to your own fork.
- **Conventional commits**: Enforced by commitlint (`@commitlint/config-conventional`).
- **Branch-based deployment**: The branch of your local checkout determines the ArgoCD deployment target.
- **Changes require commit + push** to take effect — ArgoCD watches the remote.

## Commands Reference

All commands run via `./pattern.sh make <target>`:

| Command | Purpose |
|---|---|
| `install` | Install the pattern and load secrets |
| `show` | Render the starting template without installing |
| `preview-all` | Preview all applications across cluster groups |
| `validate-schema` | Validate values files against JSON schema |
| `validate-cluster` | Validate cluster prerequisites |
| `super-linter` | Run super-linter locally |
| `load-secrets` | Load secrets into the configured backend |
| `uninstall` | Uninstall the pattern |

See the readme for secrets backend configuration, RHDP environment variables, and additional maintenance commands.

## Validation and CI

CI runs the following checks on pull requests:

- **JSON schema validation** — values files validated against `common/clustergroup` schema
- **Super Linter** — multi-language linting
- **Conventional PR title lint** — PR titles must follow conventional commit format

Run locally before pushing:

```bash
./pattern.sh make preview-all
./pattern.sh make validate-schema
```
