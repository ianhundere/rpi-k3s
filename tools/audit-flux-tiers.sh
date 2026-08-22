#!/usr/bin/env bash
# Assert the rendered Flux controller resource tiers still match intent. The
# patch targets in clusters/rpi-k3s/flux-system/kustomization.yaml FAIL OPEN --
# kustomize exits 0 and silently drops a patch whose target matches nothing, so
# a gotk-components regen without --components-extra, an upstream rename, or a
# reordered patch list reverts a tier with no error surface at all.
#
# Usage:  tools/audit-flux-tiers.sh [path/to/flux-system]
#         (defaults to clusters/rpi-k3s/flux-system; run from the repo root)
# Exit:   0 all good, 1 drift found, 2 could not audit
set -uo pipefail

DIR="${1:-clusters/rpi-k3s/flux-system}"
[ -d "$DIR" ] || { echo "not a directory: $DIR" >&2; exit 2; }
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 2; }

RENDERED=$(kubectl kustomize "$DIR" 2>&1) || {
  echo "kustomize build failed:" >&2; echo "$RENDERED" >&2; exit 2; }

# heredoc into a var, not into stdin -- stdin carries the rendered manifests
PYSRC=$(cat <<'PY'
import sys, re, pathlib
try:
    import yaml
except ImportError:
    print("  PyYAML not installed"); sys.exit(2)

# Intent, stated independently of the manifest so drift actually fails.
# GOMEMLIMIT: "literal" means detached from limits.memory via valueFrom: null,
# so go gc runs before the cgroup killer instead of at the same byte.
EXPECTED = {
    "source-controller":           {"mem": "384Mi", "gomemlimit": None},
    "kustomize-controller":        {"mem": "384Mi", "gomemlimit": None},
    "helm-controller":             {"mem": "256Mi", "gomemlimit": None},
    "notification-controller":     {"mem": "256Mi", "gomemlimit": None},
    "image-automation-controller": {"mem": "256Mi", "gomemlimit": None},
    "image-reflector-controller":  {"mem": "512Mi", "gomemlimit": "448MiB"},
}

docs = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") == "Deployment"]
rendered = {d["metadata"]["name"]: d for d in docs}
rc = 0

def fail(msg):
    global rc
    print(f"  FAIL {msg}")
    rc = 1

missing = set(EXPECTED) - set(rendered)
extra = set(rendered) - set(EXPECTED)
for n in sorted(missing):
    fail(f"{n}: expected in the render, absent -- tier silently dropped?")
for n in sorted(extra):
    fail(f"{n}: rendered but not in this script's expected table -- update intent")

for name in sorted(set(EXPECTED) & set(rendered)):
    want = EXPECTED[name]
    c = next((c for c in rendered[name]["spec"]["template"]["spec"]["containers"]
              if c["name"] == "manager"), None)
    if c is None:
        fail(f"{name}: no container named 'manager'"); continue

    res = c.get("resources", {})
    req = res.get("requests", {}).get("memory")
    lim = res.get("limits", {}).get("memory")

    if lim != want["mem"] or req != want["mem"]:
        fail(f"{name}: memory req/lim {req}/{lim}, expected {want['mem']}/{want['mem']}")
    elif req != lim:
        fail(f"{name}: memory request {req} != limit {lim} (house invariant)")

    # no cpu limits: cfs quota throttles even on idle cpus, ugly on rpi
    if res.get("limits", {}).get("cpu") is not None:
        fail(f"{name}: has limits.cpu {res['limits']['cpu']}, house convention is none")

    env = {e["name"]: e for e in c.get("env", [])}
    g = env.get("GOMEMLIMIT")
    if want["gomemlimit"] is None:
        if g is not None and "valueFrom" not in g:
            fail(f"{name}: GOMEMLIMIT unexpectedly a literal ({g.get('value')})")
    else:
        if g is None:
            fail(f"{name}: GOMEMLIMIT absent, expected literal {want['gomemlimit']}")
        elif "valueFrom" in g:
            fail(f"{name}: GOMEMLIMIT still tracks limits.memory -- go gc gets zero "
                 f"margin before the cgroup killer")
        elif g.get("value") != want["gomemlimit"]:
            fail(f"{name}: GOMEMLIMIT {g.get('value')}, expected {want['gomemlimit']}")

# the fail-open guard: every named patch target must match a rendered Deployment
kpath = pathlib.Path(sys.argv[1]) / "kustomization.yaml"
if not kpath.exists():
    kpath = pathlib.Path(sys.argv[1]) / "kustomization.yml"
if kpath.exists():
    k = yaml.safe_load(kpath.read_text()) or {}
    for p in k.get("patches", []):
        target = (p.get("target") or {})
        if target.get("kind") != "Deployment":
            continue
        pat = target.get("name")
        if not pat:
            continue  # unnamed target = every Deployment, cannot fail open
        if not any(re.search(pat, n) for n in rendered):
            fail(f"patch target /{pat}/ matched no rendered Deployment -- "
                 f"kustomize dropped this patch silently")
else:
    print("  WARN kustomization not found, skipped the fail-open target check")

print("  all tiers, invariants and patch targets check out" if rc == 0 else "")
sys.exit(rc)
PY
)
printf '%s' "$RENDERED" | python3 -c "$PYSRC" "$DIR"
