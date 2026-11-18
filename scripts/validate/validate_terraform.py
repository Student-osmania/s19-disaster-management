"""Usage: python scripts/validate/validate_terraform.py <repo-root>"""
"""Static Terraform checks without the terraform binary/providers (registry.terraform.io is blocked here):
 * every .tf file parses as HCL2
 * every var.X is declared, every resource/data reference points at a declared block
 * 02-platform reads only outputs that 01-foundation declares
 * every file()/source path used exists."""
import pathlib, re, sys
import hcl2
ROOT = pathlib.Path(sys.argv[1]); fails = []
def ok(c, m):
    print(("  [PASS] " if c else "  [FAIL] ") + m)
    if not c: fails.append(m)
mods = {}
uq = lambda k: k.strip('"')
for d in ["00-bootstrap", "01-foundation", "02-platform"]:
    md = ROOT / "infra/terraform" / d; text = ""; parsed = []
    print(f"== {d}")
    for f in sorted(md.glob("*.tf")):
        t = f.read_text(); text += t + "\n"
        try: parsed.append(hcl2.loads(t)); ok(True, f"{f.name} parses")
        except Exception as e: ok(False, f"{f.name}: {e}")
    decl_vars = {uq(list(v)[0]) for p in parsed for v in p.get("variable", [])}
    used_vars = set(re.findall(r"\bvar\.([a-zA-Z_][\w]*)", text))
    ok(used_vars <= decl_vars, f"variables used {sorted(used_vars)} all declared" + ("" if used_vars <= decl_vars else f" MISSING {used_vars - decl_vars}"))
    res = {(uq(t), uq(n)) for p in parsed for r in p.get("resource", []) for t, body in r.items() for n in body if n != "__is_block__"}
    dat = {(uq(t), uq(n)) for p in parsed for r in p.get("data", []) for t, body in r.items() for n in body if n != "__is_block__"}
    refs = set(re.findall(r"(?<![\w.\"])((?:google|kubernetes|helm|random|archive)_[a-z0-9_]+)\.([a-zA-Z_][\w-]*)", text))
    bad = {r for r in refs if r not in res}
    ok(not bad, f"{len(refs)} resource references resolve" + ("" if not bad else f" UNRESOLVED {sorted(bad)}"))
    drefs = set(re.findall(r"\bdata\.([a-z0-9_]+)\.([a-zA-Z_][\w-]*)", text))
    ok(drefs <= dat, f"{len(drefs)} data-source references resolve")
    locs = {uq(k) for p in parsed for l in p.get("locals", []) for k in l}
    lrefs = set(re.findall(r"\blocal\.([a-zA-Z_]\w*)", text))
    ok(lrefs <= locs, f"locals used {sorted(lrefs)} declared")
    outs = {uq(list(o)[0]) for p in parsed for o in p.get("output", [])}
    mods[d] = {"outs": outs, "text": text, "dir": md}
    for m in re.finditer(r'(?:file|fileexists)\("\$\{path\.module\}/([^"]+)"\)|source\s*=\s*"\$\{path\.module\}/([^"]+)"', text):
        rel = m.group(1) or m.group(2); ok((md / rel).exists(), f"path {rel} exists")
    m = re.search(r'source_dir\s*=\s*"\$\{path\.module\}/([^"]+)"', text)
    if m: ok((md / m.group(1)).resolve().is_dir(), f"function source_dir {m.group(1)} exists")
f_used = set(re.findall(r"\blocal\.f\.([a-zA-Z_]\w*)", mods["02-platform"]["text"]))
ok(f_used <= mods["01-foundation"]["outs"], f"02-platform reads foundation outputs {sorted(f_used)} - all declared")
print(f"\n{'ALL TERRAFORM STATIC CHECKS PASSED' if not fails else str(len(fails)) + ' FAILED'}")
sys.exit(1 if fails else 0)
