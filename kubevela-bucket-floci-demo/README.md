# KubeVela bucket demo on Floci: one interface, CUE and DevKit, AWS and GCP

One Application, `product-catalog`, promoted through three stages. Each stage gets a bucket from a different backing, and the developer's properties never change; only the definition types do:

| Stage (namespace) | Component | HA trait | Written in | Bucket |
|---|---|---|---|---|
| `aws-cue` | `bucket-aws-cue` | `high-availability` | CUE (`definitions/`) | S3 in [Floci](https://github.com/floci-io/floci) |
| `aws-devkit` | `bucket-aws-devkit` | `high-availability-devkit` | Go, with DevKit (`devkit/`) | S3 in Floci |
| `gcp-devkit` | `bucket-gcp-devkit` | `high-availability-devkit` | Go, with DevKit | Cloud Storage in [floci-gcp](https://github.com/floci-io/floci-gcp) |

Crossplane creates every bucket, through provider-aws-s3 or provider-gcp-storage. The app is the product-catalog API from kubevela-one-interface-demos, which stores products in whichever bucket it is given.

The Application's workflow deploys a stage, then creates a product through that stage's API. That fails the workflow unless the API can write to its bucket. Before each later stage it waits for approval. Each stage also raises the HA trait's level: `dev` (1-2 replicas), `staging` (1-3, a disruption budget, spread across nodes), `prod-local` (3-6).

The Application is defined once, in `apps/product-catalog.yaml`. Each stage's override policy picks its bucket component and its HA trait, so the DevKit stages differ from `aws-cue` only in those types. `cd devkit && go test ./...` checks that the DevKit definitions render the same resources as the CUE ones, and that each stage's definitions accept its properties.

## Run it

On a host with Docker:

```bash
./demo.sh
```

It creates the k3d cluster `kubevela-bucket-floci-demo` (1 server, 2 agents), builds and imports the `product-catalog` image, and installs Floci, floci-gcp, KubeVela with VelaUX, and Crossplane with both providers. Then it applies the CUE and DevKit definitions, deploys the Application, and walks the promotion, asking before each approval. As soon as the `aws-cue` stage is deployed it forwards VelaUX to http://localhost:8000 (user `admin`, password `VelaUX12345` or `VELAUX_ADMIN_PASSWORD`), so you can follow the promotion there. The forward keeps running after `demo.sh` ends; `./clean.sh` stops it. Set `VELAUX_LOCAL_PORT` if 8000 is taken.

Needs `docker`, `k3d`, `kubectl`, `helm`, Go 1.27+ (for the DevKit module) and the vela CLI v1.12.0-alpha.1:

```bash
curl -fsSl https://kubevela.io/script/install.sh | bash -s v1.12.0-alpha.1
```

Options:

- `--auto-approve` promotes without asking. So does any run without a terminal.
- `--skip-cluster` uses the current kubectl context.
- `--skip-build` skips the image build when the image is already in the cluster.
- `--zscaler` trusts a TLS-inspecting proxy's CA. It mounts `~/zscaler/zscaler_root.crt`, or `REGISTRY_CA_BUNDLE`, into the k3d nodes at cluster creation, so run `./clean.sh` first if the cluster was created without it.

Run one demo cluster at a time. Rancher Desktop allows 128 inotify instances, and with two k3d clusters `kubevela-vela-core` crash-loops with `too many open files`. Delete the other cluster or raise `fs.inotify.max_user_instances`.

Tear down with `./clean.sh`, or `./clean.sh --apps-only` to delete only the Application and its buckets.

## Promote by hand

```bash
vela status product-catalog                   # workflow steps and each stage's health
vela workflow resume product-catalog          # approve the next stage
kubectl get buckets.s3.aws.upbound.io,buckets.storage.gcp.upbound.io
kubectl get pods -n aws-cue                   # likewise aws-devkit and gcp-devkit
kubectl port-forward -n gcp-devkit svc/product-catalog-api 8080:8080   # then curl localhost:8080/products
```

## How the GCP bucket reaches floci-gcp

Crossplane's GCP ProviderConfig has no endpoint field. The provider runs the Terraform Google provider inside, though, and that reads `GOOGLE_STORAGE_CUSTOM_ENDPOINT` from its environment. `demo.sh` sets it on the provider pod through a DeploymentRuntimeConfig. The ProviderConfig uses an access token, which floci-gcp doesn't check.

## Layout

| Path | What it is |
|---|---|
| `demo.sh`, `clean.sh` | Bring the demo up and tear it down |
| `floci/` | Floci and floci-gcp, and the Crossplane ProviderConfigs pointing at them |
| `definitions/components/bucket-aws-cue.cue` | The CUE bucket component |
| `definitions/traits/high-availability.cue` | The `high-availability` trait, from kubevela-one-interface-demos |
| `apps/product-catalog.yaml` | The Application: components, stage policies and the promotion workflow |
| `devkit/` | The DevKit bucket components and `high-availability-devkit` trait; see `devkit/README.md` |
| `app/` | The product-catalog API (Flask) and its Dockerfile |

## Changes from kubevela-one-interface-demos

- `app/storage.py` addresses S3 buckets by path when `AWS_ENDPOINT_URL` is set, since Floci doesn't serve `<bucket>.<host>` virtual hosts. Against floci-gcp the GCS client needs nothing: `STORAGE_EMULATOR_HOST` makes it use anonymous credentials.
- The bucket components create Crossplane managed resources directly rather than through a composition, and take the same parameters as there (`name`, `region`, `versioning`, `projectName`). `region` is limited to the regions `bucket-gcp-devkit` can map to a GCS location.
- One Application promotes across backings, where the original deploys one backing per run.
