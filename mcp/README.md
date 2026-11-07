# KubeVela MCP demo

A guided live demo of `vela mcp`: an AI agent debugs a broken Application, deploys Spring Petclinic, then helps a platform engineer add a Postgres component and moves Petclinic onto it. An optional act 4 creates a DynamoDB table through ACK.

The scripts come from [this gist](https://gist.github.com/anoop2811/cc37a4a43e2036377c4057ec3bc55e13). The gist's header refers to a `demo-script.md` that is not in this repo.

| Script | Use |
|---|---|
| [`demo-init-kubecon.sh`](demo-init-kubecon.sh) | The one to run. Adapted to this repo's shared `kubecon` cluster |
| [`demo-init.sh`](demo-init.sh) | The gist as published, unchanged. It creates its own `vela-demo` cluster and pins vela-core 1.11.1 |

## What the adapted script changes

- It never creates or deletes a cluster. It reuses `k3d-kubecon`, which `kubevela-bucket-floci-demo/demo.sh` creates.
- It uses the vela CLI in `~/workspace/kubevela/bin` (or `VELA`), and never clones or builds kubevela.
- It expects vela-core 1.12.0-alpha.1 and leaves it alone unless you pass `--upgrade`.
- `reset` removes only the DynamoDB ACK CRDs, so the bucket demo's ACK S3 setup survives.

## Run it

1. Create the cluster, once: `../kubevela-bucket-floci-demo/demo.sh --cluster-only`. Add `--zscaler` behind a TLS-inspecting proxy.
2. Build the vela CLI from a kubevela `master` checkout: `make -C ~/workspace/kubevela vela-cli`. It needs the `mcp` command and `def init-module --components`.
3. Run `./demo-init-kubecon.sh`. It clones the skills into `./kubevela-demo`, adds CloudNativePG and a Floci emulator to the cluster, seeds act 1, then walks the acts one Enter at a time. It prints the Claude Code and Codex setup for the MCP server, with writes allowed only in the `petclinic` namespace.

Other subcommands: `up` (provision only), `ack [--floci]` (act 4), `check` (pre-talk checklist), `diag` (why pods were evicted), `reset` (undo what the demo adds, keep the cluster). `./demo-init-kubecon.sh --help` lists the settings.

## Needs

Docker, k3d, kubectl, helm, go, git and python3, about 4 CPUs, 8 GiB of memory and 15 GiB of free Docker disk. It runs on the host, not in the dev container.

`reset` and the leftovers step delete the demo's Applications and definitions, and everything in the agent's working folder except the skill links. Check which cluster `check` reports before you run them.
