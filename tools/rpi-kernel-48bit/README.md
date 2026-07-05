# 48-bit VA kernels for the Raspberry Pi nodes

## Why

Envoy's statically-linked Google TCMalloc **requires a 48-bit virtual address
space**. Stock Raspberry Pi OS kernels ship `CONFIG_ARM64_VA_BITS=39`, so every
official arm64 Envoy binary aborts instantly on an RPi node:

```
MmapAligned() failed … TCMalloc assumes a 48-bit virtual address space
```

Upstream will not fix this (envoy#23339 — maintainer verdict: *"recompile Envoy
or use a kernel which supports it"*; google/tcmalloc#82 open, `kAddressBits=48`
hardcoded for aarch64). Custom 48-bit kernels were first built in 2026-03 but
were installed **over `kernel8.img`**, so the stock `linux-image-rpi-v8`
6.12.87 package update silently destroyed them — causing the 2026-07-05
Envoy data-plane crashloop (121 restarts / 10h) and the interim amd64 pin
(rpi-k3s#49).

## The clobber-proof mechanism

1. The custom kernel is installed as **`/boot/firmware/kernel8-48bit.img`** —
   a filename no apt package owns or writes.
2. `kernel=kernel8-48bit.img` in `config.txt` makes the firmware boot it.
   apt kernel updates keep writing `kernel8.img`, which is unused but stays
   fresh as an instant rollback target.
3. A post-apt hook (`/etc/apt/apt.conf.d/99-48bit-kernel-guard`) warns on every
   apt run if the pin or the kernel file ever goes missing.
4. `apt-mark hold linux-image-rpi-v8` is **deliberately not used**: with the
   custom filename the stock package can't hurt us, and letting it update keeps
   the fallback kernel patched. (Hold it anyway if you prefer belt-and-braces —
   it's harmless, just noisy on upgrades.)

Stock DTBs/overlays are kept (same-series 6.12.y DTBs are compatible); the
build ships only the kernel Image + its module tree.

## Usage

```bash
# 1. Build (x86_64 workstation, aarch64-linux-gnu- toolchain, ~15-25 min)
./build-48bit-kernel.sh                     # → out/rpi-kernel-48bit-<ver>-<sha>.tar.gz

# 2. Per node, canary-style (worker first, kube-master LAST):
./install-48bit-kernel.sh kube-worker1 out/<tarball> stage     # copy files, no reboot
./install-48bit-kernel.sh kube-worker1 out/<tarball> tryboot   # drain + ONE-SHOT boot
# … validate (below) …
./install-48bit-kernel.sh kube-worker1 out/<tarball> promote   # permanent + guard + uncordon

# Rollback at any point:
./install-48bit-kernel.sh <node> out/<tarball> rollback
```

### Validation battery (per node, after tryboot and again after promote)

```bash
ssh <node> uname -r                          # expect …-v8-48bit
# The decisive test — official Envoy must start where it used to abort:
kubectl run envoy-va-check --image=docker.io/envoyproxy/envoy:distroless-v1.38.3 \
  --restart=Never --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"<node>"}}}' \
  -- --version
kubectl logs envoy-va-check   # expect a version banner, NOT the MmapAligned abort
kubectl delete pod envoy-va-check
kubectl get node <node>       # Ready
```

### Risk notes

- `tryboot` is one-shot: a panicking kernel reboots back onto stock. A **hung**
  kernel needs a physical power cycle (the node is drained, so the cluster is
  fine meanwhile). Canary on a worker; do kube-master last.
- Node reboots move single-replica workloads (quixit app, postgres are on
  worker4/amd64 and are not touched by RPi reboots).

## Un-pin criteria (rpi-k3s#49)

Once **all four** RPi nodes run the 48-bit kernel with the guard installed,
remove the `kubernetes.io/arch: amd64` nodeSelector from
`infrastructure/envoy-gateway/envoyproxy.yml` (revert of #49) so the Envoy
data plane can schedule anywhere again — eliminating the worker4 ingress SPOF.

## Refresh procedure

Rebuild when the RPi kernel series moves (e.g. 6.12 → 6.15) or ~quarterly:
re-run `build-48bit-kernel.sh` (it tracks `rpi-6.12.y` — bump `KERNEL_BRANCH`
when the series changes), then `stage` + `tryboot` + `promote` per node. The
old module tree can be removed after the new one is promoted.
