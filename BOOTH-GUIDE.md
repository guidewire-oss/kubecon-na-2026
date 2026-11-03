# KubeCon NA 2026 booth guide: one interface to rule them all

For whoever is standing at the booth. Modeled on the India team's
`kubevela-one-interface-demos/demos/kubecon-in-2026/walkthrough.md`, but shorter:
a pitch, one demo loop and answers to the usual questions.

The demo is `kubevela-bucket-floci-demo/`. The slides are the deck "One
Interface To Rule Them All".

## The message

Said from the developer's side: I write one `application.yaml` that declares my app, its traits and its bucket. I deploy it, and the same properties go to every stage, so there's nothing to edit. My app code stays as it is too, because the platform provides the abstraction.

That single interface frees us from two choices. Crossplane or ACK can build the bucket, and AWS S3 or GCP GCS can hold it. The developer's file is the same either way.

## The 30-second pitch

> One Application, four stages. Every stage gets its bucket from something
> different: Crossplane, ACK, even a different cloud. Look at the developer's
> file: the properties are the same every time. Approve the next stage here
> and watch its bucket appear on the right.

## Before the doors open

1. Docker running, one demo cluster only (see Troubleshooting).
2. `cd kubevela-bucket-floci-demo && ./demo.sh --open` (add `--zscaler` behind Zscaler, after `./clean.sh`).
3. Check both windows are up, side by side:
   - VelaUX: http://localhost:8000 (`admin` / `VelaUX12345`, or `VELAUX_ADMIN_PASSWORD`)
   - Bucket browser: http://localhost:8081
4. `vela status product-catalog` should show the first stage, `aws-cue`, healthy.
5. Put the slide deck on the second screen, on the "My application.yaml" slide.

## The demo loop (about 3 minutes)

Run it once per visitor group. Each step names the thing to point at.

| Step | You do | You say | Point at |
|---|---|---|---|
| 1 | Show `apps/product-catalog.yaml` | "This is the developer's whole input. Three bucket properties." | `name`, `region`, `projectName` |
| 2 | Look at the bucket browser | "Stage one is live: S3 via Crossplane, written in CUE." | The `aws-cue` card, with its mug |
| 3 | Approve the next stage in VelaUX (or `vela workflow resume product-catalog`) | "Same properties. The platform now writes its definitions in Go, with DevKit." | `DevKit` in red on the `aws-devkit` card |
| 4 | Approve again | "Same bucket, but ACK builds it instead of Crossplane." | `ACK` in red on the `aws-ack` card |
| 5 | Approve again | "Now a different cloud: GCP Cloud Storage. Still the same properties." | `GCP GCS` in red on the `gcp-devkit` card |
| 6 | Say it | "Four backings. One file. Nothing the developer wrote changed." | The four cards together |

Red in the bucket browser always means "this changed from the stage before".

## What each stage is

| Stage | Bucket | Created by | Written in |
|---|---|---|---|
| `aws-cue` | S3 in Floci | Crossplane | CUE |
| `aws-devkit` | S3 in Floci | Crossplane | Go, with DevKit |
| `aws-ack` | S3 in Floci | ACK | Go, with DevKit |
| `gcp-devkit` | Cloud Storage in floci-gcp | Crossplane | Go, with DevKit |

Floci and floci-gcp are local emulators, so the demo needs no cloud account.
Say so if someone asks whether it's real: the controllers and the definitions
are real; only the cloud API is emulated.

## Questions you'll get

**What actually changes between stages?**
Only the component type, picked by an override policy for that stage. The
properties are passed through as written. `kubevela-bucket-floci-demo/apps/product-catalog.yaml` shows it.

**Doesn't the app change when the cloud changes?**
No. The code talks to one `ObjectStore` interface (`app/storage.py`). The
platform sets `STORAGE_PROVIDER` for the stage, and the same image runs on S3
or Cloud Storage.

**Why CUE and DevKit?**
They are two ways for the platform team to write the same definitions. DevKit
lets them write Go with tests and an IDE. A Go test checks the DevKit
definitions against the CUE ones, so they stay equivalent.

**Why Crossplane and ACK?**
Both are IaC controllers for Kubernetes. The point is that you can swap one
for the other without the developer noticing.

**Can we add another cloud or another tool?**
Yes: add a bucket component for it, add a stage with an override, and add the
stage to `apps/bucket-browser.yaml`'s `BUCKETS`. The developer's file doesn't change.

**Where are the pictures from?**
`./seed-products.sh` posts each stage's mug through its API. They use the
official KubeVela, Guidewire, AWS and Google Cloud logos; see `sample/LOGOS.md`.

## Reset between visitors

```bash
./clean.sh --apps-only        # delete the Application and its buckets, keep the cluster
./demo.sh --skip-cluster --skip-build   # bring it back on the same cluster
```

`--apps-only` empties the ACK bucket first, because ACK can't delete a bucket
that still has objects in it. A full teardown is `./clean.sh`.

## Troubleshooting

- **`vela-core` in `CrashLoopBackOff` with `too many open files`.** Two k3d clusters on one Rancher Desktop VM. Delete one, or raise `fs.inotify.max_user_instances`.
- **A stage's bucket shows "Bucket not created yet".** Its stage isn't approved yet. Check `vela status product-catalog`.
- **A card shows an error instead of products.** The stage is deployed, but its API can't reach its bucket. `kubectl get pods -n <stage>`, then re-run `./seed-products.sh <stage>`.
- **No mugs showing.** Run `./seed-products.sh`. A stage that already has its mug is left alone.
- **Nothing responds on 8000 or 8081.** The port-forwards died. Re-run `./demo.sh --skip-cluster --skip-build`.
- **The `vela` CLI doesn't match.** The demo pins v1.12.0-alpha.1: `curl -fsSl https://kubevela.io/script/install.sh | bash -s v1.12.0-alpha.1`.

## Useful commands

```bash
vela status product-catalog                 # workflow steps and each stage's health
vela workflow resume product-catalog        # approve the next stage
kubectl get buckets.s3.aws.upbound.io,buckets.storage.gcp.upbound.io   # Crossplane's buckets
kubectl get buckets.s3.services.k8s.aws -n aws-ack                      # ACK's bucket
./seed-products.sh [stage...]               # add each stage's mug
```
