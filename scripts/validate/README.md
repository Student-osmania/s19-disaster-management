# Offline validators (no cluster, no cloud, no Terraform binary needed)

```powershell
python -m pip install pyyaml kubernetes-validate python-hcl2
python scripts/validate/validate_manifests.py .    # renders the kustomizations, schema-validates (Kubernetes 1.33), cross-checks references
python scripts/validate/validate_terraform.py .    # parses every .tf file and checks every var./resource/data/local/output reference
```
Both print `[PASS]`/`[FAIL]` lines and exit non-zero on any failure. They complement (do not replace) `terraform validate` and Argo CD's own sync.
