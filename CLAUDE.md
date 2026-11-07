# CLAUDE.md - KubeCon NA 2026

## Working in this repo

- `kubevela-bucket-floci-demo/demo.sh` pins `VELA_VERSION` (v1.12.0-alpha.1); the `vela` CLI must match it
- DefKit tests: `cd kubevela-bucket-floci-demo/defkit && go test ./...` (no cluster). They check the DefKit definitions against the CUE ones, and every stage of `apps/product-catalog.yaml` against its definitions, so change CUE and DefKit together
- The Application is defined once, in YAML; each stage's override policy picks its bucket component and HA trait. Overrides match traits by type, so a stage-specific trait goes in the override, not the base component
- Behind Zscaler: `./demo.sh --zscaler`. The CA is mounted into the k3d nodes only at cluster creation, so run `./clean.sh` first
- vela-core `CrashLoopBackOff` with `too many open files` = two k3d clusters on one Rancher Desktop VM (128 inotify instances); delete one or raise `fs.inotify.max_user_instances`
- ACK's S3 controller reads ~20 bucket settings per reconcile and fails on any error; Floci 2.3.0 serves all but `GetBucketAbac`, which falls through harmlessly. Re-check before bumping Floci (README "How ACK reaches Floci")
- ACK can't delete a non-empty bucket and has no forceDestroy; `clean.sh --apps-only` empties the `aws-ack` bucket through the API pod first
- Adding or renaming a stage means updating `apps/bucket-browser.yaml`'s `BUCKETS` too (the bucket browser, `app/browser.py`); `apptest` fails until they match
- The API stores pictures base64-decoded from `image_data`; `./seed-products.sh [stage...]` posts each stage's mug
- A workflow step's `timeout` goes on the step, not in `properties` (the `request` step doesn't accept it there); `topology` policies don't create namespaces, so `demo.sh` creates the four stage namespaces
- Go tests read the CUE definitions from outside the `defkit` module, so `go test` can serve a cached result after a CUE-only change: use `-count=1`
- defkit 1.12 quirks are in `kubevela-bucket-floci-demo/defkit/README.md`
- `vela1.12-preview-demo/` holds the per-feature demo scripts and videos; its README table has one line per feature, so update it when you add or remove a feature folder
- `posters/` holds each Letter poster as a kebab-case `.pdf` plus a same-named `.png` preview that the README embeds; regenerate the PNG when the PDF changes
- `gh pr create` fails here (the EMU token can't open PRs); `origin` uses the SSH alias `github.com-kubevela` (`~/.ssh/id_ed25519_kubevela`), so merge locally and `git push origin main`
- Dev containers can't run k3d; use `./demo.sh --skip-cluster --skip-build` against an existing context that already has `product-catalog:latest`
