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
6.12.87 package update silently destroyed them — causing the 2026-07-05 Envoy
data-plane crashloop (121 restarts / 10h) and the interim amd64 pin (rpi-k3s#49).

## The clobber-proof mechanism

1. The custom kernel lives at **`/boot/firmware/kernel8-48bit.img`** — a
   filename no apt package owns or writes. `kernel=kernel8-48bit.img` in
   `config.txt` boots it. apt keeps updating the unused stock `kernel8.img`,
   which stays fresh as the rollback target.
2. **Trial-file staging:** `stage` writes `kernel8-48bit-trial.img` and never
   touches the pinned kernel — so a **refresh** of an already-promoted node has
   the same safety as the first install: the running kernel is only replaced by
   `promote`, *after* the trial has successfully booted.
3. A post-apt hook (`99-48bit-kernel-guard`) checks the pin after every dpkg
   operation and, if broken, prints a WARNING **and** logs to journald
   (`logger -p user.err -t 48bit-kernel-guard`). `promote` validates the guard
   with `apt-get check` before declaring success. Note the hook fires on
   package operations (install/upgrade/remove), not on bare `apt update`.
4. `apt-mark hold linux-image-rpi-v8` is deliberately **not** used: with the
   custom filename the stock package can't hurt us, and letting it update keeps
   the fallback kernel patched. (Hold anyway if you want belt-and-braces.)

Stock DTBs/overlays are kept (same-series 6.12.y DTBs are compatible); the
build ships only the kernel Image + its module tree.

**No-initramfs contract:** with `kernel=kernel8-48bit.img`, `auto_initramfs=1`
no longer name-matches an initramfs, so the custom kernel boots without one
(side effect: no early-boot fsck of the rootfs — run `sudo fsck -fn /dev/mmcblk0p2`
manually if SD corruption is ever suspected).
That is safe **only because** the SD-card rootfs path is built-in — the build
script asserts `CONFIG_MMC_BCM2835=y`, `CONFIG_MMC_SDHCI_IPROC=y`,
`CONFIG_EXT4_FS=y` and fails the build if a future defconfig demotes them.

## Usage

```bash
# 1. Build (x86_64 workstation, aarch64-linux-gnu- toolchain, ~15-25 min)
./build-48bit-kernel.sh                     # → out/rpi-kernel-48bit-<ver>-<sha>.tar.gz

# 2. Per node — canary a worker first, kube-master LAST (control-plane API is
#    down during its reboot; find problems on workers first):
./install-48bit-kernel.sh kube-worker1 out/<tarball> stage     # trial file, no reboot
./install-48bit-kernel.sh kube-worker1 out/<tarball> tryboot   # drain + ONE-SHOT boot
# … validate (below) …
./install-48bit-kernel.sh kube-worker1 out/<tarball> promote   # pin + guard + reboot + verify + uncordon

# Rollback at any point (drains, removes pin+guard, reboots to stock, verifies):
./install-48bit-kernel.sh <node> out/<tarball> rollback
```

### Validation battery (after tryboot, and again after promote)

```bash
ssh <node> uname -r     # expect …-v8-48bit+
# Decisive test — official Envoy must start where it used to abort with exit 133.
# nodeName (not nodeSelector) bypasses the scheduler, so this runs on the
# still-CORDONED node during the tryboot window:
kubectl run envoy-va-check --image=docker.io/envoyproxy/envoy:distroless-v1.38.3 \
  --restart=Never --overrides='{"spec":{"nodeName":"<node>"}}' -- --version
kubectl logs envoy-va-check          # expect a version banner, NOT MmapAligned
kubectl delete pod envoy-va-check
# k3s health on the new kernel (CNI sandbox creation is exercised by the pod
# above; also confirm the node's daemonsets recovered):
kubectl get node <node>              # Ready,SchedulingDisabled (cordoned until promote)
kubectl get pods -A -o wide --field-selector spec.nodeName=<node>   # daemonsets Running
```

### Fleet check (the un-pin gate)

All four RPi nodes must pass before removing the Envoy amd64 pin:

```bash
for n in kube-worker1 kube-worker2 kube-worker3 kube-master; do
  echo "== $n: $(ssh $n 'uname -r; grep -c ^kernel=kernel8-48bit.img /boot/firmware/config.txt; test -f /etc/apt/apt.conf.d/99-48bit-kernel-guard && echo guard-ok' | paste -sd" ")"
done   # each line: <release ending -v8-48bit+> 1 guard-ok
```

### Risk notes — read before the first tryboot

- `tryboot` is one-shot and `tryboot` ensures `panic=10` in `cmdline.txt`, so a
  **panicking** trial kernel self-reboots back onto the stock config within
  ~10s. A **hung** trial kernel does NOT self-recover — it needs a physical
  power cycle (the node is drained first, so the cluster is fine meanwhile).
  After any power event which kernel boots is decided by `config.txt`: stock
  unless `promote` has pinned.
- If `drain` fails (PDB / stuck pod) the script stops with the node cordoned
  and tells you; nothing has been rebooted at that point.
- Node reboots move single-replica workloads. quixit app + postgres live on
  worker4 (amd64) and are untouched by RPi reboots.

## Un-pin criteria (rpi-k3s#49)

Once the **fleet check** above passes on all four RPi nodes, remove the
`kubernetes.io/arch: amd64` nodeSelector from
`infrastructure/envoy-gateway/envoyproxy.yml` (revert of #49) so the Envoy data
plane can schedule anywhere again — eliminating the worker4 ingress SPOF.

## Refresh procedure

Rebuild when the RPi kernel series moves (e.g. 6.12 → 6.15) or ~quarterly.
Because `stage` writes only the trial file, a refresh is **identical to a first
install**: `build` → `stage` → `tryboot` → validate → `promote`, per node. The
build script re-asserts the no-initramfs contract each time. Old module trees
under `/lib/modules/` can be pruned after the new release is promoted
everywhere.
