# CLAUDE.md - KubeCon NA 2026

## Working in this repo

- `kubevela-bucket-floci-demo/demo.sh` pins `VELA_VERSION` (v1.12.0-alpha.1); the `vela` CLI must match it
- DevKit tests: `cd kubevela-bucket-floci-demo/devkit && go test ./...` (no cluster). They check the DevKit definitions against the CUE ones, and every stage of `apps/product-catalog.yaml` against its definitions, so change CUE and DevKit together
- The Application is defined once, in YAML; each stage's override policy picks its bucket component and HA trait. Overrides match traits by type, so a stage-specific trait goes in the override, not the base component
- Behind Zscaler: `./demo.sh --zscaler`. The CA is mounted into the k3d nodes only at cluster creation, so run `./clean.sh` first
- vela-core `CrashLoopBackOff` with `too many open files` = two k3d clusters on one Rancher Desktop VM (128 inotify instances); delete one or raise `fs.inotify.max_user_instances`
- defkit 1.12 quirks are in `kubevela-bucket-floci-demo/devkit/README.md`
- Dev containers can't run k3d; use `./demo.sh --skip-cluster --skip-build` against an existing context that already has `product-catalog:latest`
