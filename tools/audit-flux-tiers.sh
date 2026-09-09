#!/usr/bin/env bash
# Assert the Flux controller resource tiers still match intent, twice: once
# against the render, once against the live cluster.
#
# Render pass: the patch targets in clusters/rpi-k3s/flux-system/kustomization.yaml
# FAIL OPEN -- kustomize exits 0 and silently drops a patch whose target matches
# nothing, so a gotk-components regen without --components-extra, an upstream
# rename, or a reordered patch list reverts a tier with no error surface at all.
#
# Live pass: a green render is intent, not proof. In 2026-08 the render was
# correct while the running image-reflector still had the old tier (a stale
# `flux` field manager co-owned the fields), and it OOMKilled 132x unnoticed.
#
# Usage:  tools/audit-flux-tiers.sh [path/to/flux-system]
#         (defaults to clusters/rpi-k3s/flux-system; run from the repo root)
# Exit:   0 all good, 1 drift found, 2 could not audit (no cluster => render-only)
set -uo pipefail

DIR="${1:-clusters/rpi-k3s/flux-system}"
[ -d "$DIR" ] || { echo "not a directory: $DIR" >&2; exit 2; }
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 2; }

RENDERED=$(kubectl kustomize "$DIR" 2>&1) || {
  echo "kustomize build failed:" >&2; echo "$RENDERED" >&2; exit 2; }

# heredoc into a var, not into stdin -- stdin carries the rendered manifests
PYSRC=$(cat <<'PY'
import sys, re, json, pathlib, subprocess
try:
    import yaml
except ImportError:
    print("  PyYAML not installed"); sys.exit(2)

NS = "flux-system"
KUBECTL_TIMEOUT = "--request-timeout=15s"

# Intent, stated independently of the manifest so drift actually fails.
# GOMEMLIMIT: "literal" means detached from limits.memory via valueFrom: null,
# so go gc runs before the cgroup killer instead of at the same byte.
EXPECTED = {
    "source-controller":           {"mem": "384Mi", "gomemlimit": "320MiB"},
    "kustomize-controller":        {"mem": "384Mi", "gomemlimit": "320MiB"},
    "helm-controller":             {"mem": "256Mi", "gomemlimit": "200MiB"},
    "notification-controller":     {"mem": "256Mi", "gomemlimit": "200MiB"},
    "image-automation-controller": {"mem": "256Mi", "gomemlimit": "200MiB"},
    "image-reflector-controller":  {"mem": "512Mi", "gomemlimit": "448MiB"},
}

docs = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") == "Deployment"]
rendered = {d["metadata"]["name"]: d for d in docs}
rc = 0

def fail(msg, where="render"):
    global rc
    print(f"  FAIL [{where}] {msg}")
    rc = 1

def manager(dep):
    return next((c for c in dep["spec"]["template"]["spec"]["containers"]
                 if c["name"] == "manager"), None)

def check_container(name, c, want, where):
    """mem req == lim == tier, no cpu limit, GOMEMLIMIT a literal. same intent
    both passes -- the render says what we asked for, live says what we got."""
    ok = True
    res = c.get("resources", {})
    req = res.get("requests", {}).get("memory")
    lim = res.get("limits", {}).get("memory")

    if lim != want["mem"] or req != want["mem"]:
        fail(f"{name}: memory req/lim {req}/{lim}, expected {want['mem']}/{want['mem']}", where)
        ok = False

    # no cpu limits: cfs quota throttles even on idle cpus, ugly on rpi
    if res.get("limits", {}).get("cpu") is not None:
        fail(f"{name}: has limits.cpu {res['limits']['cpu']}, house convention is none", where)
        ok = False

    g = {e["name"]: e for e in c.get("env", [])}.get("GOMEMLIMIT")
    if g is None:
        fail(f"{name}: GOMEMLIMIT absent, expected literal {want['gomemlimit']}", where)
        ok = False
    elif "valueFrom" in g:
        fail(f"{name}: GOMEMLIMIT still tracks limits.memory -- go gc gets zero "
             f"margin before the cgroup killer", where)
        ok = False
    elif g.get("value") != want["gomemlimit"]:
        fail(f"{name}: GOMEMLIMIT {g.get('value')}, expected {want['gomemlimit']}", where)
        ok = False
    return ok

# --- render pass
missing = set(EXPECTED) - set(rendered)
extra = set(rendered) - set(EXPECTED)
for n in sorted(missing):
    fail(f"{n}: expected in the render, absent -- tier silently dropped?")
for n in sorted(extra):
    fail(f"{n}: rendered but not in this script's expected table -- update intent")

for name in sorted(set(EXPECTED) & set(rendered)):
    c = manager(rendered[name])
    if c is None:
        fail(f"{name}: no container named 'manager'"); continue
    check_container(name, c, EXPECTED[name], "render")

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

if rc == 0:
    print("  render: all tiers, invariants and patch targets check out")

# --- live pass: assert the cluster actually carries what the render promises.
# No cluster is "could not audit" (exit 2), not drift -- degrade to render-only
# so this stays runnable off-network without going red.
probe = subprocess.run(["kubectl", "get", "deploy", "-n", NS, KUBECTL_TIMEOUT, "-o", "name"],
                       capture_output=True, text=True, stdin=subprocess.DEVNULL)
if probe.returncode != 0:
    # kubectl puts four klog lines ahead of the human one; the last is the useful one
    lines = [l for l in (probe.stderr or "").strip().splitlines() if l.strip()]
    print("  live:   SKIPPED, cluster unreachable -- render-only audit")
    if lines:
        print(f"          {lines[-1][:140]}")
    sys.exit(1 if rc else 2)

live_ok = 0
for name in sorted(EXPECTED):
    p = subprocess.run(["kubectl", "get", "deploy", name, "-n", NS, KUBECTL_TIMEOUT, "-o", "json"],
                       capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if p.returncode != 0:
        fail(f"{name}: in the render but not in the cluster", "live"); continue
    c = manager(json.loads(p.stdout))
    if c is None:
        fail(f"{name}: live Deployment has no container named 'manager'", "live"); continue
    if check_container(name, c, EXPECTED[name], "live"):
        live_ok += 1

if live_ok == len(EXPECTED):
    print(f"  live:   all {live_ok} controllers in the cluster match the tiers")
else:
    print(f"  live:   {live_ok}/{len(EXPECTED)} controllers match -- "
          f"reconcile flux-system, or the SSA field-manager remedy in AGENTS.md")
sys.exit(rc)
PY
)
printf '%s' "$RENDERED" | python3 -c "$PYSRC" "$DIR"
