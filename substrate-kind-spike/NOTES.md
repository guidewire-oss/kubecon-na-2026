# Agent Substrate install spike (kind, Substrate v1.0.0)

Findings from running `ate-setup deploy ate-system` against the kind cluster
this folder creates. Input for the `agent-substrate` addon for kubevela/catalog.

## Command used

```bash
ATE_INSTALL_KIND=true NO_DEV_ENV=1 go run ./cmd/ate-setup deploy ate-system \
  --context kind-substrate \
  --image-repo ghcr.io/agent-substrate/substrate --image-tag v1.0.0 \
  --sandbox-classes=gvisor \
  --credential-provider='{"name":"k8s.io"}' \
  --ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/ate-system/sa/atenet-client
```

Run from a checkout of `agent-substrate/substrate` at tag `v1.0.0` (releases ship
no `ate-setup` binary, so it needs Go 1.27). Took about 2 minutes. KubeVela
1.12.0-alpha.1 was installed first with the floci demo's helm flags.

## Cluster requirements

- `ClusterTrustBundle`, `ClusterTrustBundleProjection`, `PodCertificateRequest`
  feature gates and `certificates.k8s.io/v1beta1` (kind v1.37 serves them as `v1`).
- Proxy ARP on the nodes (gVisor loopback networking).

## What it creates

- CRDs: `workerpools`, `sandboxconfigs`, `csidriverconfigs` (`ate.dev`). Only
  `SandboxConfig/gvisor-default` is created (cluster-scoped, version v7).
- Namespaces: `ate-system`, `podcertificate-controller-system`.
- `ate-system` workloads: `ate-api-server` (2), `ate-controller`, `ate-idp-server`
  (2), `atelet` (DaemonSet), `atenet-router`, `atenet-egress`,
  `k8s-credential-provider`, `postgres` (StatefulSet), `rustfs` and a bucket-init
  Job (kind overlay snapshot storage).
- Also: 10 NetworkPolicies, 2 PDBs, a ResourceQuota, 9 ServiceAccounts, roles,
  cluster roles and bindings, and ClusterTrustBundles for pod identity, service
  DNS, postgres and egress MITM.
- Images (all digest-pinned by ate-setup): `ghcr.io/agent-substrate/substrate/`
  `ateapi`, `atecontroller`, `ate-idp-server`, `atelet`, `atenet`,
  `envoy-dataplane`, `kubernetes-secrets`, `podcertcontroller`, all `v1.0.0`;
  plus `postgres:18-alpine`, `rustfs/rustfs:1.0.3`, `amazon/aws-cli:2.38.5`.

## Imperative steps (cannot be static manifests)

`ate-setup` generates these at install time; a rendered addon must create them
with a Job or init step, or generate them in the addon template:

- `create_jwt_authority_pool_secret` -> `actor-id-jwt-pool`
- `create_actor_id_ca_pool_secret` / `create_actor_id_ca_certs_secret`
  -> `actor-id-ca-pool`, `actor-id-ca-certs`
- `create_api_server_env_vars` -> `ate-api-server-envvars` (ConfigMap) and
  `ate-api-server-secret-envvars` (Secret)
- `create_api_config`, `create_api_authentication_config`
- `create_podcertificate_controller_cas` -> `pod-identity-ca-pool`,
  `postgres-ca-pool`, `service-dns-ca-pool`
- `create_egress_mitm_ca_pool_secret` -> `egress-mitm-ca-pool`
- the `k8s-credential-provider` namespace policy (default-deny)

## Smoke test

A `WorkerPool` (namespace `spike`, `workerImage`
`ghcr.io/agent-substrate/substrate/ateworker-gvisor:v1.0.0`, sandbox class
`gvisor` -> `gvisor-default`) went Ready in under a minute. atelet downloaded the
gVisor release from `gs://gvisor/...` on its own, so no Zscaler CA was needed
on this network.

## Better install path: kagent-dev Helm charts (verified)

`kagent-dev/substrate` (a fork of `agent-substrate/substrate`) publishes Helm
charts that upstream v1.0.0 does not have. They replace most of `ate-setup`:

- `oci://ghcr.io/kagent-dev/substrate/helm/{substrate-crds,substrate-podcert,substrate-atelet,substrate}`
  (1.0.0 and 1.0.1 exist; images come from `ghcr.io/kagent-dev/substrate`)
- `oci://ghcr.io/kagent-dev/kagent/helm/{kagent-crds,kagent}` (1.0.1)
- kagent CLI v1.0.1 release assets include `kagent-<os>-<arch>` with sha256 files.

`kagent install --dry-run --output-dir DIR` exports the ordered `helm upgrade
--install` commands and the values per release, without touching a cluster.
Order: `kagent-crds`, `substrate-crds`, `substrate-podcert`, `substrate-atelet`
(wait for the DaemonSet), `substrate`, `kagent`. The CLI's real run also deploys
a bundled PostgreSQL in the kagent namespace, creates the identities, schemas and
connection Secrets, and creates the `kagent-rustfs-credentials` Secret.

Ran `kagent install --provider OpenAI -n kagent` with a placeholder key against
this cluster (after removing the ate-setup install). It exited 0 in about 4
minutes: all `ate-system` and `kagent` pods Running, `WorkerPool/kagent-default`
Ready on `gvisor-default`, Harnesses `kagent-default`, `codex-default`,
`claude-default`, `ModelConfig/default-model-config`.

An `Agent` (`harnessRef: kagent-default`, inline template, `default-model-config`)
reached `Ready=True` and the condition "ActorTemplate golden snapshot is ready".
So kagent creates the Substrate `ActorTemplate` through the API; KubeVela only
applies kagent CRs. Model calls need a real provider key, which was not tested.

Addon implications:

- `agent-substrate` can install these charts instead of rendering `ate-setup`
  output. The imperative secrets and CAs in the section above are handled by the
  charts and the CLI's setup steps; check which of them the charts create versus
  the CLI (PostgreSQL, rustfs credentials, podcert CA pools).
- `kagent` depends on `agent-substrate`; its values set the Substrate endpoints,
  `controller.substrateClientCertificate`, `database.postgres.clientCertificate`,
  `harnesses.enabled` and `substrateWorkerPool.create`.
- Remaining prerequisite work: PostgreSQL with certificate auth, rustfs
  credentials, `substrate-podcert` `postgresClients` entries.

## What the kagent CLI does beyond `helm install` (must become declarative)

From `kagent/go/core/pkg/install` (`substrate_init.go`, `postgres.go`,
`bundled_postgres.yaml`):

1. Namespaces `kagent`, `ate-system`, `podcertificate-controller-system`; label
   `ate.dev/api-access=true` on the kagent namespace.
2. Generated key material, created only if missing: `actor-id-jwt-pool`,
   `actor-id-ca-pool` (ed25519), `actor-id-ca-certs`, `egress-mitm-ca-pool`
   (ECDSA P-256) in `ate-system`; `service-dns-ca-pool`, `pod-identity-ca-pool`,
   `postgres-ca-pool` (ed25519) in `podcertificate-controller-system`.
3. `ate-api-authentication` ConfigMap (JWT provider, issuer discovered from the
   cluster).
4. `kagent-rustfs-credentials` Secret (matches the chart's rustfs keys).
5. Bundled PostgreSQL (`kagent-postgresql` Deployment, PVC, ConfigMap, TLS
   reloader) plus a SQL setup script run with `kubectl exec` (roles, schemas,
   certificate identities `kagent_owner_user`, `kagent_readwrite_user`).
6. Helm releases in order, with an atelet rollout wait between them.

## KubeVela main building blocks for a GitOps addon (checked on 1.12.0-alpha.1)

- Component types in `vela-system`: `helmchart` (native Helm, no Flux; OCI
  charts, `valuesFrom` Secret/ConfigMap, wait/atomic options), `module` (fetches
  a module and installs its owned Application), `addon`, `k8s-objects`.
- Module format (`pkg/module`): `_module.cue`, `auxiliary/` (any K8s objects,
  YAML or CUE, applied in source order; a tier is "healthy" once applied, it
  does not wait for readiness), `vN/_version.cue`, `vN/auxiliary/`,
  `vN/definitions/`; `hub`/`runtime` placement. Installs as Application
  `module-<name>` in `vela-system`.
- Addons can bundle modules inline (`modules/`), and their `resources/` are
  Application components, so `helmchart` components with dependencies can live
  there. KEP-2.13 describes a declarative `Addon` CR; there is no Addon CRD in
  1.12.0-alpha.1 yet, only the `addon` component type.

## GitOps prototype (`gitops/`): verified, no CLI

`gitops/build.py` writes `application.json`, one KubeVela Application
(`agent-platform`, `vela-system`) with 11 components in dependency order:
`namespaces` -> `platform-base` (RBAC, scripts, SQL ConfigMaps) ->
`substrate-bootstrap` (`ate-job`) -> `substrate-crds` -> `substrate-podcert` ->
`postgres` (kagent's bundled manifest) -> `postgres-setup` (`ate-job`) ->
`substrate-atelet` -> `substrate` -> `kagent-crds` -> `kagent`.
`definitions/ate-job.cue` is a Job component that is healthy only once complete.
Applied to a clean cluster, every workflow step succeeded; the control plane,
kagent and the `kagent-default` WorkerPool came up, and a test `Agent` went
`Ready=True` once a (placeholder) model key reached the chart.

- `scripts/gen-pools.sh` (openssl container, tested standalone) generates the CA
  and JWT pools in kagent's installer format; `scripts/apply-pools.sh` (kubectl
  container) creates only missing Secrets, so reruns keep keys. Substrate and
  kagent accepted them, so the format matches.
- Postgres setup runs the two upstream SQL files through `kubectl exec` into the
  database pod, as the CLI does (needs `pods/exec` RBAC in `kagent`).
- The model API key is not in Git: the `kagent` helmchart has
  `valuesFrom: Secret kagent-provider-values` (key `values.yaml`, optional). A
  Secret change is picked up on the next Application reconcile, not instantly
  (it took an annotation bump here).
- Run it: `python3 build.py` (needs kubectl and a cluster only to convert the
  Postgres manifest), `vela def apply definitions/ate-job.cue -n vela-system`,
  `kubectl apply -f application.json`.

Limitations and follow-ups:

- A Job's pod template is immutable, so changing the bootstrap or setup Job needs
  a delete and re-apply (use a name suffix or `ttlSecondsAfterFinished`).
- Rustfs credentials are the chart defaults (`rustfsadmin`); generate and share
  them with the chart values instead.
- CAs expire after 365 days and nothing rotates them (same as the CLI).
- KubeVela dry-runs every object of a k8s-objects component before applying any,
  so a component cannot create a namespace and objects in it; namespaces are
  their own component.
- `postgres` is considered healthy once applied; `postgres-setup` waits for the
  rollout itself.
- This is the Application the addons below generate.

## Addons (`kubevela/catalog`, branch `feat/agent-substrate-addon`): verified

Committed as `45d7521` and pushed to the fork `jguionnet/catalog` (not yet a PR).

`experimental/addons/agent-substrate` and `experimental/addons/kagent` (kagent
depends on agent-substrate). Tested with `vela addon enable ./<dir>` on a clean
kind cluster running KubeVela 1.12.0-alpha.1, using a `vela` 1.11.1 CLI (the
build of main failed on a full disk, so the main CLI is untested here):
disable both -> cluster empty (no namespaces, CRDs or Applications left) ->
enable agent-substrate, then kagent -> an `Agent` reaches `Ready=True`.

Differences from the plain Application prototype:

- No custom Job component: an addon cannot use its own definitions in its own
  Application (admission rejects the unknown type). Jobs are `k8s-objects`;
  later steps wait through Helm's `wait`.
- Static objects are `package main` components in `resources/*.cue` with explicit
  `dependsOn`. Any `resources/*.yaml` becomes one merged component that cannot
  create a namespace and objects in it.
- The shared Postgres runs in `ate-system`. The chart's `postgres` NetworkPolicy
  only admits `app=postgres` on a port named `postgres`, so the addon adds
  `shared-postgres` (API server, and namespaces labelled
  `ate.dev/database-access=true`). Without it the API server hangs on the database.
- A changed `kagent-provider-values` Secret needs `vela addon enable ./kagent`
  again plus an Application annotation bump before the chart is upgraded.
- A full host disk makes rustfs fail snapshot copies ("Disk full"), and agents
  stay `ActorTemplatePending`.
- Object names still say `kagent-postgresql` and `kagent-rustfs-credentials` in
  `ate-system`; rename them in a follow-up.

## Modules (`kubevela/catalog`, branch `fix/substrate-modules-nested-app`): verified

The addons ported to 1.12 modules in `experimental/modules/{agent-substrate,kagent}`
(0.2.0, commit `0d143ba`, pushed to the fork). `create-kind-cluster1.12.sh` publishes
them to a local OCI registry and deploys them. Verified on 2026-11-20: all nested
workflow steps succeeded, all pods ran, and `apps/hello-agent.yaml` (through the
module's `kagent/v1/agent` definition) reached `Ready=True` with a placeholder key.

The nested Application must be the first object of its tier (`00-application.yaml`),
or it passes the tier's `trait.oam.dev/resource` label down to every Helm-rendered
object and the `helmchart` step fails. The `filter.oam.dev/*` annotations do not
help, because vela-core strips them. Details are in the catalog `experimental/modules/README.md`.

## Known limitation: disabling `agent-substrate` destroys its data

Deleting the prototype `agent-platform` Application removed everything it had
created, including the namespaces. The `agent-substrate` addon has the same
shape: it creates `ate-system` and runs the shared Postgres there on a PVC. So
`vela addon disable agent-substrate` deletes the namespace, the database (actor
state, kagent data), and the CA and signing-key Secrets the bootstrap Job made.
Re-enabling generates new keys.

Accepted for now (experimental addon); document it in the addon README. Options
for later: keep namespaces and the PVC out of the addon's cleanup (for example a
resource-policy keep on them), support an external database through parameters,
or move stateful objects to a separate, deliberately-deleted addon.

## Gotchas

- `ate-setup delete ate-system` left the `sandboxconfig-assets`
  ValidatingAdmissionPolicy and binding behind, which blocked the Helm install
  ("exists and cannot be imported"). Delete both before switching install paths.
- Do not mix the two install paths on one cluster.

## Not yet verified

- Running the Agent (an `ate` Actor invocation) and real model calls.
- Upgrade and uninstall behavior of the chart-based install.
- Whether `substrate` 1.0.1 charts work with the kagent 1.0.1 chart (the CLI
  pins Substrate chart 1.0.0).
