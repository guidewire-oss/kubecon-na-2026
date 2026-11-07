# KubeCon NA 2026 booth guide

Three demos, in this order:

1. **One interface to rule them all**: `kubevela-bucket-floci-demo/`
2. **KubeVela 1.12 preview**: `vela1.12-preview-demo/`
3. **KubeVela MCP**: `mcp/`

The first two share one k3d cluster, `kubecon`, and the 1.12 preview `vela` CLI. The MCP demo needs a
different `vela` CLI (see "Two vela CLIs"). Each demo has a short section below; the first has a fuller
guide in its own folder.

The [KubeVela 1.12 Kiosk artifact](https://claude.ai/artifact/95bdXESvfeDNLQvbmrRAm8) covers the
**1.12 preview demos only**: every example, code, and videos.

## Needs

Docker, k3d, kubectl, helm, go, git and python3, about 4 CPUs, 8 GiB of memory and 15 GiB of free
Docker disk. Run on the host, not in a dev container. Internet access is needed for images and charts.

## Two vela CLIs

| Demos | `vela` CLI | Where |
|---|---|---|
| 1. One interface, 2. 1.12 preview | 1.12 preview (v1.12.0-alpha.1) | On `PATH`: `curl -fsSl https://kubevela.io/script/install.sh \| bash -s v1.12.0-alpha.1` |
| 3. MCP | 1.11, built from source, with the `mcp` command | Demo laptop: `~/workspace/kubevela/bin/vela`, already built. Any other laptop: `demo-init.sh` checks out kubevela and builds it |

Keep the preview CLI on `PATH` and never replace it with the built one. On the demo laptop the MCP
script uses the built CLI through `VELA`, which defaults to `~/workspace/kubevela/bin/vela`:

```bash
vela version                              # must say 1.12.0-alpha.1 (demos 1 and 2)
~/workspace/kubevela/bin/vela version     # the MCP CLI (demo 3)
```

## 1. One interface to rule them all

Two people: the developer writes one `application.yaml` that never changes; the platform engineer
writes the components behind it, in CUE or in Go with DefKit. Full guide, with questions and
troubleshooting: [`kubevela-bucket-floci-demo/BOOTH-GUIDE.md`](kubevela-bucket-floci-demo/BOOTH-GUIDE.md).

Boot (creates the `kubecon` cluster and the app):

```bash
cd kubevela-bucket-floci-demo
./demo.sh --open        # --open opens VelaUX and the bucket browser on macOS; elsewhere open the URLs
```

- VelaUX: http://localhost:8000 (`admin` / `VelaUX12345`, or `VELAUX_ADMIN_PASSWORD`)
- Bucket browser: http://localhost:8081
- `vela status product-catalog` should show the first stage, `aws-cue`, healthy.

The loop (about 3 minutes): show `apps/product-catalog.yaml` ("three bucket properties, that's the whole
input"), then approve the next stage in VelaUX (or `vela workflow resume product-catalog`) three times.
Red in the bucket browser means "changed from the stage before".

| Stage | Bucket | Created by | Written in |
|---|---|---|---|
| `aws-cue` | S3 in Floci | Crossplane | CUE |
| `aws-defkit` | S3 in Floci | Crossplane | Go, with DefKit |
| `aws-ack` | S3 in Floci | ACK | Go, with DefKit |
| `gcp-defkit` | Cloud Storage in floci-gcp | Crossplane | Go, with DefKit |

Floci and floci-gcp are local emulators, so no cloud account is needed.

Reset between visitors:

```bash
./clean.sh --apps-only                    # delete the Application and its buckets, keep the cluster
./demo.sh --skip-cluster --skip-build     # bring it back
```

## 2. KubeVela 1.12 preview

Reuses the `kubecon` cluster from demo 1.

```bash
cd vela1.12-preview-demo
./00-setup.sh             # installs/checks vela-core 1.12.0-alpha.1 with the alpha gates and VelaUX
./00-setup.sh --cleanup   # delete the cluster
```

VelaUX: `vela port-forward addon-velaux-prerelease -n vela-system 8000:8000`, then http://localhost:8000.
The first visit may ask you to create the admin user (8 to 16 characters, letters and digits).

Every script applies an example, checks the result and prints `PASS`; run it with `--cleanup` to remove
what it created. One example per feature:

| Feature | Say | Run | Show |
|---|---|---|---|
| VelaUX | "The UI got a refresh: layout, graphs, loops, reports, permissions." | Open VelaUX | `media/vx-nav.mp4` if the cluster is not up |
| Sources | "The replica count lives in a ConfigMap the platform owns. Patch it and the app rescales, with no edit to the Application." | `sources/01-scale-from-configmap.sh` | `kubectl patch` the ConfigMap, watch the Deployment |
| CEL expressions | "`$( ... )` in any string property, evaluated at render time." | `cel/01-render-context.sh` | Env vars filled from where the app renders |
| Workflow loops | "One step, run once per item, with per-item status and restart." | `loops/01-one-step-three-items.sh` | Three ConfigMaps from one step; `media/loops-restart.mp4` for restart |
| Declarative addons | "An addon is just a component. It lives in Git." | `addons/01-one-addon.sh` | kube-state-metrics installed by `type: addon` |
| Native Helm | "A real Helm release with no FluxCD addon." | `helm/01-chart-from-repo.sh` | podinfo from its repo; `helm ls` |
| Configs | "Config and ConfigTemplate are real CRDs now." | `configs/01-template-and-config.sh` | The template renders a ConfigMap from a Config |
| Definition inheritance | "A definition builds on another with `extends`." | `inheritance/01-tenant-app.sh` | `tenant-app` extends `webservice`; the platform fixes port and labels |
| Definition tests | "Unit tests for definitions, offline." | `testing/01-component-render.sh` | `vela def test` on `web.cue` and `web_test.cue` |

Sources, CEL, addons and inheritance are Alpha, behind gates that `00-setup.sh` turns on.

Alpha.1 gotchas: `$( )` in `type: addon` or `type: helmchart` properties is refused at admission, and
`vela def test` panics on a definition that uses `extends` (show inheritance and tests separately). The
artifact's Overview tab lists the rest.

## 3. KubeVela MCP

An agent debugs a broken Application, deploys Petclinic, then helps add a Postgres component. Run it
last: it adds CloudNativePG and Floci to the `kubecon` cluster.

Pick the script by laptop:

| Laptop | Script | What it does |
|---|---|---|
| Demo laptop | `./demo-init-kubecon.sh` | Uses the already built CLI at `~/workspace/kubevela/bin/vela`. Reuses the `kubecon` cluster (vela-core 1.12.0-alpha.1, as installed by demos 1 and 2). Never creates or deletes a cluster |
| Any other laptop | `./demo-init.sh` | Checks out kubevela `master` into `./kubevela-demo` and builds the CLI there. Reuses a reachable local cluster or creates its own k3d cluster `vela-demo`, and pins vela-core 1.11.1 |

```bash
cd mcp
./demo-init-kubecon.sh check    # demo laptop: pre-talk checklist (cluster, versions, CLI); non-zero if off
./demo-init-kubecon.sh          # demo laptop: the guided demo, one Enter per step

./demo-init.sh                  # any other laptop: builds everything, then the guided demo
```

Both add CloudNativePG and Floci, clone the skills, and print the Claude Code and Codex setup for the
MCP server, with writes allowed only in the `petclinic` namespace.

Other subcommands (same on both): `up` (provision only), `ack [--floci]` (optional act 4, DynamoDB),
`diag`, `check`, `reset`. On the demo laptop `reset` removes only what the demo added, so demo 1's ACK
setup survives. It deletes the demo's Applications and definitions, so check which cluster `check`
reports first.

## Troubleshooting

- **`vela-core` in `CrashLoopBackOff` with `too many open files`.** Two k3d clusters on one Docker VM. Delete one, or raise `fs.inotify.max_user_instances`.
- **Wrong `vela` version.** Demos 1 and 2 need 1.12.0-alpha.1 on `PATH`; demo 3 on the demo laptop needs the built CLI, via `VELA=~/workspace/kubevela/bin/vela`.
- **Gates are off.** Re-run `vela1.12-preview-demo/00-setup.sh`; it fails by gate name.
- **Nothing on port 8000 or 8081.** Re-run `./demo.sh --skip-cluster --skip-build`, or the `vela port-forward` command above.
