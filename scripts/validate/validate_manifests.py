"""Usage: python scripts/validate/validate_manifests.py <repo-root>"""
"""Static validation of the Kubernetes / GitOps manifests without a cluster.
 * renders kustomizations (resources, namespace, images, configMapGenerator) like `kustomize build`
 * validates core kinds against the official Kubernetes JSON schemas (kubernetes-validate)
 * cross-checks: selectors vs pod labels, Service targetPorts, HPA targets, Ingress backends,
   ServiceMonitor ports, envFrom ConfigMaps/Secrets, Argo CD Application paths, PDB selectors."""
import json, pathlib, sys
import yaml, kubernetes_validate

ROOT = pathlib.Path(sys.argv[1])
K8S_VERSION = "1.33.0"
fails = []
def ok(c, msg):
    print(("  [PASS] " if c else "  [FAIL] ") + msg)
    if not c: fails.append(msg)

def load_docs(p):
    return [d for d in yaml.safe_load_all(p.read_text()) if d]

def render(kdir):
    k = yaml.safe_load((kdir / "kustomization.yaml").read_text())
    docs = []
    for r in k.get("resources", []):
        p = (kdir / r).resolve()
        docs += render(p) if p.is_dir() else load_docs(p)
    for g in k.get("configMapGenerator", []):
        data = {pathlib.Path(f).name: (kdir / f).read_text() for f in g.get("files", [])}
        labels = (g.get("options") or {}).get("labels", {})
        docs.append({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": g["name"], "labels": labels}, "data": data})
    if "namespace" in k:
        for d in docs: d.setdefault("metadata", {})["namespace"] = k["namespace"]
    for im in k.get("images", []):
        for d in docs:
            for c in (d.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])):
                if c["image"].split(":")[0] == im["name"]:
                    c["image"] = f"{im.get('newName', im['name'])}:{im.get('newTag', 'latest')}"
    return docs

def schema_validate(docs, title):
    for d in docs:
        kind, name = d["kind"], d["metadata"]["name"]
        if d["apiVersion"].split("/")[0] in ("monitoring.coreos.com", "cloud.google.com", "argoproj.io"):
            ok(all(k in d for k in ("apiVersion", "kind", "metadata", "spec")), f"{title}: CRD {kind}/{name} has apiVersion/kind/metadata/spec")
            continue
        try:
            kubernetes_validate.validate(d, K8S_VERSION, strict=True)
            ok(True, f"{title}: {kind}/{name} valid against Kubernetes {K8S_VERSION} schema")
        except Exception as e:  # noqa
            ok(False, f"{title}: {kind}/{name}: {str(e)[:200]}")

print("== deploy/k8s/overlays/gcp (tracked by Argo CD app s19-services)")
svc = render(ROOT / "deploy/k8s/overlays/gcp")
schema_validate(svc, "s19")
by = {}
for d in svc: by.setdefault(d["kind"], {})[d["metadata"]["name"]] = d
workloads = {**by.get("Deployment", {}), **by.get("StatefulSet", {})}
ok(len(workloads) == 7, f"7 containerised services rendered: {sorted(workloads)}")
ok(all(d["metadata"].get("namespace") == "s19" for d in svc), "every object lands in namespace s19")
for n, w in workloads.items():
    sel = w["spec"]["selector"]["matchLabels"]; lab = w["spec"]["template"]["metadata"]["labels"]
    ok(all(lab.get(k) == v for k, v in sel.items()), f"{n}: selector matches pod labels")
    img = w["spec"]["template"]["spec"]["containers"][0]["image"]
    ok(img.startswith("us-central1-docker.pkg.dev/") and img.endswith(":v1") or "REPLACE_PROJECT_ID" in img, f"{n}: image rewritten by overlay -> {img}")
    for ef in w["spec"]["template"]["spec"]["containers"][0].get("envFrom", []):
        cm = ef.get("configMapRef", {}).get("name")
        ok(cm in by.get("ConfigMap", {}) or cm == "s19-cloud-config", f"{n}: envFrom ConfigMap {cm} exists in Git or is created by Terraform 02-platform")
    for e in w["spec"]["template"]["spec"]["containers"][0].get("env", []):
        sk = (e.get("valueFrom") or {}).get("secretKeyRef")
        if sk: ok(sk["name"] == "s19-secrets" and sk["key"] in ("DB_PASSWORD", "ADMIN_TOKEN"), f"{n}: secret {sk['name']}/{sk['key']} is created by Terraform 02-platform")
    ok(w["spec"]["template"]["spec"].get("serviceAccountName") == "s19-app", f"{n}: runs as Workload-Identity KSA s19-app")
for n, s in by.get("Service", {}).items():
    sel = s["spec"]["selector"]
    tgt = [w for w in workloads.values() if all(w["spec"]["template"]["metadata"]["labels"].get(k) == v for k, v in sel.items())]
    ok(len(tgt) == 1, f"Service {n} selects exactly one workload")
    if tgt:
        names = {p.get("name") for p in tgt[0]["spec"]["template"]["spec"]["containers"][0]["ports"]}
        ok(all(p["targetPort"] in names for p in s["spec"]["ports"]), f"Service {n}: targetPorts {[p['targetPort'] for p in s['spec']['ports']]} exist on the pod")
for n, h in by.get("HorizontalPodAutoscaler", {}).items():
    t = h["spec"]["scaleTargetRef"]["name"]
    ok(t in by.get("Deployment", {}) and "replicas" not in by["Deployment"][t]["spec"], f"HPA {n} targets Deployment {t} (which leaves spec.replicas to the HPA)")
    ok(all(m["type"] == "Resource" and m["resource"]["name"] in ("cpu", "memory") for m in h["spec"]["metrics"]), f"HPA {n} scales on CPU/memory")
    c0 = by["Deployment"][t]["spec"]["template"]["spec"]["containers"][0]["resources"]["requests"]
    ok("cpu" in c0 and "memory" in c0, f"HPA {n}: target pods declare CPU+memory requests (required for Utilization)")
ok(len(by.get("HorizontalPodAutoscaler", {})) >= 2, "at least two HPAs")
ing = by["Ingress"]["s19-public"]
for p in ing["spec"]["rules"][0]["http"]["paths"]:
    b = p["backend"]["service"]
    ok(b["name"] in by["Service"] and any(x["port"] == b["port"]["number"] for x in by["Service"][b["name"]]["spec"]["ports"]), f"Ingress {p['path']} -> {b['name']}:{b['port']['number']} exists")
ok(ing["metadata"]["annotations"].get("kubernetes.io/ingress.global-static-ip-name") == "s19-ingress-ip", "Ingress uses the static IP reserved by Terraform (s19-ingress-ip)")
sm = by["ServiceMonitor"]["s19-services"]
ok({e["port"] for e in sm["spec"]["endpoints"]} <= {p.get("name") for s in by["Service"].values() for p in s["spec"]["ports"]}, "ServiceMonitor ports exist on Services")
pdb = by["PodDisruptionBudget"]["incident-store"]
ok(pdb["spec"]["selector"]["matchLabels"] == {"app": "incident-store"} and pdb["spec"]["minAvailable"] == 2, "PDB keeps 2/3 replicas (W=2/R=2) during voluntary disruptions")
for n, s in by.get("Service", {}).items():
    if "cloud.google.com/backend-config" in s["metadata"].get("annotations", {}):
        ok(json.loads(s["metadata"]["annotations"]["cloud.google.com/backend-config"])["default"] in by["BackendConfig"], f"Service {n}: BackendConfig exists")

print("== deploy/platform/kafka")
kd = render(ROOT / "deploy/platform/kafka"); schema_validate(kd, "kafka")
kenv = {e["name"]: e.get("value") for e in [d for d in kd if d["kind"] == "StatefulSet"][0]["spec"]["template"]["spec"]["containers"][0]["env"]}
lb = [d for d in kd if d["metadata"]["name"] == "kafka-external"][0]
ok(lb["spec"]["loadBalancerIP"] in kenv["KAFKA_ADVERTISED_LISTENERS"], "Kafka EXTERNAL advertised listener == internal LB IP (Dataproc reachability)")
print("== deploy/platform/monitoring/extras")
md = render(ROOT / "deploy/platform/monitoring/extras"); schema_validate(md, "monitoring")
dash = [d for d in md if d["kind"] == "ConfigMap"][0]
ok(dash["metadata"]["labels"].get("grafana_dashboard") == "1", "dashboard ConfigMap carries the Grafana sidecar label")
json.loads(list(dash["data"].values())[0]); ok(True, "dashboard JSON parses")
print("== deploy/argocd/apps")
for f in sorted((ROOT / "deploy/argocd/apps").glob("*.yaml")):
    a = yaml.safe_load(f.read_text())
    srcs = a["spec"].get("sources") or [a["spec"]["source"]]
    for s in srcs:
        if "path" in s: ok((ROOT / s["path"]).is_dir(), f"{f.name}: path {s['path']} exists in the repo")
        if s.get("ref") == "values": ok(True, f"{f.name}: values file from Git ($values)")
    ok(a["spec"]["syncPolicy"].get("automated", {}).get("selfHeal") is True, f"{f.name}: automated sync with selfHeal (GitOps)")
mon = yaml.safe_load((ROOT / "deploy/argocd/apps/20-monitoring.yaml").read_text())
vf = mon["spec"]["sources"][0]["helm"]["valueFiles"][0].replace("$values/", "")
ok((ROOT / vf).is_file(), f"monitoring Helm values file {vf} exists")
print(f"\n{'ALL MANIFEST CHECKS PASSED' if not fails else str(len(fails)) + ' FAILED'}")
sys.exit(1 if fails else 0)
