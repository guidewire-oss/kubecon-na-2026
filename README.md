# KubeCon NA 2026 demos

| Demo | What it shows |
|---|---|
| [`kubevela-bucket-floci-demo`](kubevela-bucket-floci-demo/) | One KubeVela Application promoted from a CUE-defined S3 bucket to DefKit-defined (Go) S3 and Cloud Storage buckets, created by Crossplane or ACK. The clouds are the Floci and floci-gcp emulators, on a local k3d cluster |
| [`vela1.12-preview-demo`](vela1.12-preview-demo/) | Runnable demo scripts and walkthrough videos for the KubeVela 1.12 preview (v1.12.0-alpha.1), one folder per feature. See below |

Each demo is self-contained: see its README for what it needs and how to run it.

## KubeVela 1.12 preview demo

Start with [`00-setup.sh`](vela1.12-preview-demo/00-setup.sh): it creates a k3d cluster, installs vela-core 1.12.0-alpha.1 with the feature gates the demos need, and installs the prerelease VelaUX. Each feature folder holds numbered scripts that set up an example, check the result, and remove it with `--cleanup`. The `media/` folder has the walkthrough videos.

| Feature | Folder | What it does |
|---|---|---|
| VelaUX | [`media/`](vela1.12-preview-demo/media/) | The UI refresh: new layout, application page, graphs, loops in the studio, reports and per-feature permissions. Shown in the videos |
| Sources | [`sources/`](vela1.12-preview-demo/sources/) | `spec.sources[]` fetches values the app does not own: a ConfigMap, a Config, a file in Git, a URL |
| CEL expressions | [`cel/`](vela1.12-preview-demo/cel/) | `$( ... )` in any string property, evaluated at render time against context, sources, other components and earlier steps |
| Workflow loops | [`loops/`](vela1.12-preview-demo/loops/) | `forEach` runs any workflow step once per item, with per-item status and restart |
| Declarative addons | [`addons/`](vela1.12-preview-demo/addons/) | Install addons as `type: addon` components, so the platform's addon set lives in Git and installs in order |
| Native Helm | [`helm/`](vela1.12-preview-demo/helm/) | The built-in `helmchart` component installs a real Helm release, with no FluxCD addon |
| Configs | [`configs/`](vela1.12-preview-demo/configs/) | Config and ConfigTemplate are real CRDs, with a controller, status, scoping and a migration path from the old Secrets |
| Definition inheritance | [`inheritance/`](vela1.12-preview-demo/inheritance/) | A definition builds on another with `extends`; abstract bases can only be extended |
| Definition tests | [`testing/`](vela1.12-preview-demo/testing/) | `vela def test` runs CUE unit tests for definitions, offline for renders and health |

Sources, CEL expressions, declarative addons and definition inheritance are Alpha and sit behind feature gates that are off by default; `00-setup.sh` turns them on.
