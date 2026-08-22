#!/usr/bin/env bash
# Audit whether the live Secret in the cluster still matches the SOPS-encrypted
# manifest that is supposed to define it, then reverse: every ${KEY} a manifest
# references must exist in cluster-vars or a sops file ($${KEY} escapes exempt).
#
# Usage:  tools/audit-sops-drift.sh [path/to/file.enc.yaml ...]
#         (defaults to every config/*.enc.yaml; run from the repo root)
# Exit:   0 all good, 1 drift/missing/orphan/unresolved found, 2 could not audit
set -uo pipefail

command -v sops >/dev/null || { echo "sops not found" >&2; exit 2; }
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 2; }

FILES=("$@")
[ ${#FILES[@]} -eq 0 ] && mapfile -t FILES < <(ls config/*.enc.yaml 2>/dev/null)
[ ${#FILES[@]} -eq 0 ] && { echo "no .enc.yaml files to audit" >&2; exit 2; }

rc=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "skip: $f not found"; rc=2; continue; }

  # sops -d goes straight into python over a pipe; plaintext never touches disk
  # and never reaches the terminal.
  if ! sops -d "$f" 2>/dev/null | python3 -c '
import base64, json, subprocess, sys, hashlib
try:
    import yaml
except ImportError:
    print("  PyYAML not installed"); sys.exit(2)

def digest(v: bytes) -> str:
    return hashlib.sha256(v).hexdigest()

found = False
overall = 0
for doc in yaml.safe_load_all(sys.stdin):
    if not doc or doc.get("kind") != "Secret":
        continue
    found = True
    name = doc["metadata"]["name"]
    ns = doc["metadata"].get("namespace", "default")
    print(f"  {name} (ns {ns})")

    # normalise the file side: stringData is raw, data is base64
    want = {}
    for k, v in (doc.get("stringData") or {}).items():
        want[k] = digest(str(v).encode())
    for k, v in (doc.get("data") or {}).items():
        want[k] = digest(base64.b64decode(str(v)))

    p = subprocess.run(
        ["kubectl", "get", "secret", name, "-n", ns, "-o", "json"],
        capture_output=True, text=True)
    if p.returncode != 0:
        print("    NOT IN CLUSTER — nothing to compare"); overall = 1; continue

    obj = json.loads(p.stdout)
    live = {k: digest(base64.b64decode(v))
            for k, v in (obj.get("data") or {}).items()}

    # A client-side `kubectl apply` writes every decrypted value into this
    # annotation in plaintext. It leaked 2026-04-11, was stripped, and was back
    # by 2026-08-22 — so assert its absence rather than trust it stays fixed.
    lac = "kubectl.kubernetes.io/last-applied-configuration"
    if lac in ((obj.get("metadata") or {}).get("annotations") or {}):
        print(f"    PLAINTEXT  {lac}")
        print(f"               every value readable in the clear via `kubectl "
              f"describe secret {name} -n {ns}`")
        print(f"               fix: kubectl -n {ns} annotate secret {name} {lac}-")
        overall = 1

    ok = drift = missing = 0
    for k in sorted(want):
        if k not in live:
            print(f"    MISSING  {k}  (in file, absent from cluster)"); missing += 1
        elif live[k] != want[k]:
            print(f"    DRIFT    {k}  (file and cluster differ)"); drift += 1
        else:
            ok += 1
    # A key that is in the cluster but not in sops is only harmless if nothing
    # references it. If a manifest substitutes ${KEY}, it is load-bearing and
    # exists ONLY in the live cluster — rebuilding from git would silently lose
    # it. That is the dangerous case, so it fails the audit.
    orphan = extra = 0
    for k in sorted(set(live) - set(want)):
        used = subprocess.run(
            ["grep", "-rl", "--include=*.yml", "--include=*.yaml",
             "${%s}" % k, "apps", "infrastructure", "clusters"],
            capture_output=True, text=True).stdout.split()
        if used:
            where = ", ".join(used[:3]) + (" ..." if len(used) > 3 else "")
            print(f"    ORPHAN   {k}  (cluster-only, but referenced by {where})")
            orphan += 1
        else:
            print(f"    EXTRA    {k}  (in cluster, unreferenced — stale)")
            extra += 1

    print(f"    {ok} match, {drift} drifted, {missing} missing, "
          f"{orphan} orphaned, {extra} stale")
    if drift or missing or orphan:
        overall = 1

if not found:
    print("  no Secret documents in this file"); sys.exit(2)
sys.exit(overall)
'; then
    # python exit code propagates through the pipe via PIPESTATUS
    st=${PIPESTATUS[1]:-1}
    [ "$st" -gt "$rc" ] && rc=$st
  fi
done

# --- reverse pass: a ${KEY} referenced by manifests but defined in neither
# cluster-vars nor a sops file substitutes to the literal string at build time,
# and non-strict flux won't even warn. Key names only; values never printed.
refs=$(grep -rhoP --include='*.yml' --include='*.yaml' '(?<!\$)\$\{[A-Z][A-Z0-9_]*\}' \
         apps infrastructure clusters 2>/dev/null | tr -d '${}' | sort -u)
defined=$(
  { python3 -c '
import sys, yaml
try:
    for doc in yaml.safe_load_all(open("config/cluster-vars.yaml")):
        if doc and doc.get("kind") == "ConfigMap":
            print("\n".join((doc.get("data") or {}).keys()))
except FileNotFoundError:
    print("warn: config/cluster-vars.yaml not found", file=sys.stderr)
'
    for f in "${FILES[@]}"; do
      sops -d "$f" 2>/dev/null | python3 -c '
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get("kind") == "Secret":
        print("\n".join(list(doc.get("stringData") or {}) + list(doc.get("data") or {})))
'
    done
  } | sort -u
)
unresolved=$(comm -23 <(printf '%s\n' "$refs") <(printf '%s\n' "$defined") | sed '/^$/d')
if [ -n "$unresolved" ]; then
  echo "  reverse pass:"
  while IFS= read -r k; do
    pat='(?<!\$)\$\{'"$k"'\}'
    where=$(grep -rlP --include='*.yml' --include='*.yaml' "$pat" \
              apps infrastructure clusters 2>/dev/null | head -3 | paste -sd ',' -)
    echo "    UNRESOLVED  $k  (referenced by ${where:-?}, defined nowhere)"
  done <<< "$unresolved"
  rc=1
else
  echo "  reverse pass: all referenced \${KEY}s resolve"
fi

if [ "$rc" -eq 0 ]; then
  echo "OK: cluster matches sops"
elif [ "$rc" -eq 1 ]; then
  echo "DRIFT: cluster and sops disagree (see above)"
fi
exit "$rc"
