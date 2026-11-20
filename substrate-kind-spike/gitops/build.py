#!/usr/bin/env python3
"""Builds application.json: one KubeVela Application that installs Agent Substrate
and kagent with no CLI. Inputs are the files next to this script. Needs kubectl and
a cluster only to turn the bundled Postgres manifest into JSON."""
import json, subprocess, sys
from pathlib import Path

HERE = Path(__file__).parent
KAGENT_NS, ATE_NS, PODCERT_NS = "kagent", "ate-system", "podcertificate-controller-system"
OPENSSL_IMAGE = "alpine/openssl:3.5.4"
KUBECTL_IMAGE = "alpine/k8s:1.35.5"
POSTGRES_IMAGE = "postgres:18-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15"
SUBSTRATE_REPO = "oci://ghcr.io/kagent-dev/substrate/helm"
KAGENT_REPO = "oci://ghcr.io/kagent-dev/kagent/helm"
SUBSTRATE_VERSION, KAGENT_VERSION = "1.0.0", "1.0.1"

def read(p): return (HERE / p).read_text()

def obj(api, kind, name, ns=None, **rest):
    meta = {"name": name}
    if ns: meta["namespace"] = ns
    return {"apiVersion": api, "kind": kind, "metadata": meta, **rest}

def namespace(name, labels=None):
    o = obj("v1", "Namespace", name)
    if labels: o["metadata"]["labels"] = labels
    return o

def role(ns, name, rules):
    return [obj("rbac.authorization.k8s.io/v1", "Role", name, ns, rules=rules),
            obj("rbac.authorization.k8s.io/v1", "RoleBinding", name, ns,
                roleRef={"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": name},
                subjects=[{"kind": "ServiceAccount", "name": name, "namespace": ns}])]

def sa(ns, name): return obj("v1", "ServiceAccount", name, ns)

def k8s_objects(name, objects, deps=()):
    c = {"name": name, "type": "k8s-objects", "properties": {"objects": objects}}
    if deps: c["dependsOn"] = list(deps)
    return c

def helm(name, repo, chart, version, ns, values=None, values_from=None, health=None, deps=()):
    c = {"name": name, "type": "helmchart",
         "properties": {"chart": {"source": f"{repo}/{chart}", "version": version},
                        "release": {"name": name, "namespace": ns},
                        "options": {"wait": True, "timeout": "10m", "createNamespace": False}}}
    if values: c["properties"]["values"] = values
    if values_from: c["properties"]["valuesFrom"] = values_from
    if health: c["properties"]["healthStatus"] = health
    if deps: c["dependsOn"] = list(deps)
    return c

def avail(kind, name=None):
    r = {"kind": kind}
    if name: r["name"] = name
    return {"resource": r, "condition": {"type": "Available"}}

def postgres_objects():
    text = read("postgres/bundled_postgres.yaml")
    for k, v in (("${NAMESPACE}", KAGENT_NS), ("${SUBSTRATE_NAMESPACE}", ATE_NS), ("${POSTGRES_IMAGE}", POSTGRES_IMAGE)):
        text = text.replace(k, v)
    out = subprocess.run(["kubectl", "create", "--dry-run=client", "--validate=false", "-o", "json", "-f", "-"],
                         input=text, capture_output=True, text=True, check=True).stdout
    dec, i, items = json.JSONDecoder(), 0, []
    while i < len(out):
        if out[i].isspace():
            i += 1
            continue
        item, i = dec.raw_decode(out, i)
        items.extend(item["items"] if item.get("kind") == "List" else [item])
    return items

SECRETS_RULE = {"apiGroups": [""], "resources": ["secrets", "configmaps"], "verbs": ["get", "create"]}

# --- bootstrap: namespaces, RBAC, scripts, and the idempotent key generator -------------
# Namespaces are their own component: KubeVela dry-runs every object of a component
# before applying any, so objects inside a new namespace cannot share its component.
namespaces = [namespace(ATE_NS), namespace(PODCERT_NS), namespace(KAGENT_NS, {"ate.dev/api-access": "true"})]
base_objects = [
    sa(ATE_NS, "substrate-bootstrap"), sa(PODCERT_NS, "substrate-bootstrap"),
    *role(ATE_NS, "substrate-bootstrap", [SECRETS_RULE]),
    obj("rbac.authorization.k8s.io/v1", "Role", "substrate-bootstrap", PODCERT_NS, rules=[SECRETS_RULE]),
    obj("rbac.authorization.k8s.io/v1", "RoleBinding", "substrate-bootstrap", PODCERT_NS,
        roleRef={"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "substrate-bootstrap"},
        subjects=[{"kind": "ServiceAccount", "name": "substrate-bootstrap", "namespace": ATE_NS}]),
    obj("v1", "ConfigMap", "substrate-bootstrap-scripts", ATE_NS,
        data={"gen-pools.sh": read("scripts/gen-pools.sh"), "apply-pools.sh": read("scripts/apply-pools.sh")}),
    sa(KAGENT_NS, "postgres-setup"),
    *role(KAGENT_NS, "postgres-setup", [
        {"apiGroups": [""], "resources": ["pods"], "verbs": ["get", "list"]},
        {"apiGroups": [""], "resources": ["pods/exec"], "verbs": ["create"]},
        {"apiGroups": ["apps"], "resources": ["deployments"], "verbs": ["get", "list", "watch"]}]),
    obj("v1", "ConfigMap", "postgres-setup-sql", KAGENT_NS,
        data={"kagent-setup.sql": read("sql/kagent-setup.sql"), "substrate-setup.sql": read("sql/substrate-setup.sql")}),
]
# The Role in kagent bound by role() points at SA postgres-setup in the same namespace.

bootstrap_job = {"name": "substrate-bootstrap", "type": "ate-job", "dependsOn": ["platform-base"],
    "properties": {
        "serviceAccountName": "substrate-bootstrap",
        "initContainers": [{"name": "generate", "image": OPENSSL_IMAGE, "command": ["sh", "/scripts/gen-pools.sh"],
                            "env": [{"name": "OUT", "value": "/out"}],
                            "volumeMounts": [{"name": "scripts", "mountPath": "/scripts"}, {"name": "out", "mountPath": "/out"}]}],
        "containers": [{"name": "apply", "image": KUBECTL_IMAGE, "command": ["sh", "/scripts/apply-pools.sh"],
                        "env": [{"name": "OUT", "value": "/out"}],
                        "volumeMounts": [{"name": "scripts", "mountPath": "/scripts"}, {"name": "out", "mountPath": "/out"}]}],
        "volumes": [{"name": "scripts", "configMap": {"name": "substrate-bootstrap-scripts"}},
                    {"name": "out", "emptyDir": {}}]}}
bootstrap_job["properties"]["namespace"] = ATE_NS

POSTGRES_SETUP = """set -eu
kubectl -n kagent rollout status deployment/kagent-postgresql --timeout=5m
{ echo 'BEGIN;'; cat /sql/kagent-setup.sql; echo; cat /sql/substrate-setup.sql; echo; echo 'COMMIT;'; } | \\
kubectl -n kagent exec -i deployment/kagent-postgresql -c postgresql -- \\
  psql --no-psqlrc --set=ON_ERROR_STOP=1 --username postgres --dbname kagent \\
  --set=kagent_schema=kagent --set=kagent_owner_role=kagent_owner --set=kagent_owner_user=kagent_owner_user --set=kagent_owner_password= \\
  --set=kagent_readwrite_role=kagent_readwrite --set=kagent_readwrite_user=kagent_readwrite_user --set=kagent_readwrite_password= \\
  --set=substrate_schema=substrate --set=substrate_owner_role=substrate_owner --set=substrate_owner_user=substrate_owner_user --set=substrate_owner_password= \\
  --set=substrate_readwrite_role=substrate_readwrite --set=substrate_readwrite_user=substrate_readwrite_user --set=substrate_readwrite_password=
"""
postgres_setup = {"name": "postgres-setup", "type": "ate-job", "dependsOn": ["postgres"],
    "properties": {"serviceAccountName": "postgres-setup", "namespace": KAGENT_NS,
        "containers": [{"name": "setup", "image": KUBECTL_IMAGE, "command": ["sh", "-c", POSTGRES_SETUP],
                        "volumeMounts": [{"name": "sql", "mountPath": "/sql"}]}],
        "volumes": [{"name": "sql", "configMap": {"name": "postgres-setup-sql"}}]}}

BOOTSTRAP_OWNERS = ["spiffe://cluster.local/ns/kagent/sa/kagent-controller", "system:serviceaccount:ate-system:ate-client"]
SUBSTRATE_COMMON = {
    "ateApi": {"authorization": {"bootstrapOwners": BOOTSTRAP_OWNERS}},
    "atenetRouter": {"ingressAllowedSPIFFEIDs": ["spiffe://cluster.local/ns/kagent/sa/kagent-controller"]},
    "credentialProvider": {"namespacePolicies": [{"allowedNamespaces": ["kagent"], "atespace": "kagent"}]},
    "preview": ["PerTemplateSnapshotLocation", "GoldenEgressPolicy"],
}

components = [
    k8s_objects("namespaces", namespaces),
    k8s_objects("platform-base", base_objects, deps=["namespaces"]),
    bootstrap_job,
    helm("substrate-crds", SUBSTRATE_REPO, "substrate-crds", SUBSTRATE_VERSION, ATE_NS, deps=["substrate-bootstrap"]),
    helm("substrate-podcert", SUBSTRATE_REPO, "substrate-podcert", SUBSTRATE_VERSION, PODCERT_NS,
         values={"postgresClients": ["kagent/kagent-controller=kagent_owner_user", "kagent/kagent-controller=kagent_readwrite_user"]},
         deps=["substrate-crds"]),
    k8s_objects("postgres", postgres_objects(), deps=["substrate-podcert"]),
    postgres_setup,
    helm("substrate-atelet", SUBSTRATE_REPO, "substrate-atelet", SUBSTRATE_VERSION, ATE_NS, deps=["substrate-podcert"],
         values={**SUBSTRATE_COMMON, "objectStore": {"backend": "s3", "credentialsSecret": "kagent-rustfs-credentials",
                  "endpoint": "http://rustfs.ate-system.svc:9000", "pathStyle": True, "region": "us-east-1"}}),
    helm("substrate", SUBSTRATE_REPO, "substrate", SUBSTRATE_VERSION, ATE_NS, deps=["substrate-atelet", "postgres-setup"],
         values={**SUBSTRATE_COMMON, "atelet": {"enabled": False}, "postgres": {"clientCertificates": {"enabled": True}}},
         health=[avail("Deployment", "ate-api-server"), avail("Deployment", "ate-controller")]),
    helm("kagent-crds", KAGENT_REPO, "kagent-crds", KAGENT_VERSION, KAGENT_NS, deps=["platform-base"]),
    helm("kagent", KAGENT_REPO, "kagent", KAGENT_VERSION, KAGENT_NS, deps=["substrate", "kagent-crds"],
         values={"config": {"server": {"grpcReflection": True},
                            "substrate": {"apiEndpoint": "dns:///api.ate-system.svc:443", "routerUrl": "https://atenet-router.ate-system.svc:443"}},
                 "controller": {"substrateClientCertificate": {"enabled": True}},
                 "database": {"postgres": {"clientCertificate": {"enabled": True}}},
                 "harnesses": {"enabled": True},
                 "providers": {"default": "openAI", "openAI": {"config": {"apiFormat": "responses"}, "model": "gpt-5-mini"}},
                 "substrateWorkerPool": {"create": True, "workerImage": "ghcr.io/kagent-dev/substrate/ateworker-gvisor:v1.0.0"}},
         # The provider API key comes from a Secret managed outside Git (ESO, SealedSecrets).
         values_from=[{"kind": "Secret", "name": "kagent-provider-values", "namespace": KAGENT_NS, "key": "values.yaml", "optional": True}]),
]

app = obj("core.oam.dev/v1beta1", "Application", "agent-platform", "vela-system",
          spec={"components": components})
(HERE / "application.json").write_text(json.dumps(app, indent=2) + "\n")
print(f"wrote application.json with {len(components)} components", file=sys.stderr)
