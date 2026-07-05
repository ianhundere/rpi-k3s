#!/usr/bin/env bash
# Cross-compile a Raspberry Pi OS kernel (Pi 4 / bcm2711) with 48-bit virtual
# addressing, for running Envoy (Google TCMalloc requires CONFIG_ARM64_VA_BITS=48;
# stock RPi OS kernels ship VA_BITS=39 and Envoy aborts at startup with exit 133).
#
# Runs on an x86_64 workstation with the aarch64-linux-gnu- toolchain.
# Produces: out/rpi-kernel-48bit-<kernelrelease>-<sha>.tar.gz containing
#   boot/kernel8-48bit.img          (the kernel Image, custom filename apt never touches)
#   modules/lib/modules/<release>/  (stripped module tree)
#   KERNEL_RELEASE                  (one line: the exact release string)
#
# Design notes (see README.md):
# - Custom kernel FILENAME + a `kernel=` line in config.txt is the clobber-proof
#   mechanism: apt kernel updates write kernel8.img and cannot overwrite a file
#   they do not own. (The 2026-03 build installed OVER kernel8.img and was
#   silently destroyed by the linux-image-rpi-v8 6.12.87 update.)
# - Stock DTBs/overlays are kept: same-series (6.12.y) DTBs are compatible and
#   letting apt keep refreshing them avoids a second ownership fight.
set -euo pipefail

BRANCH="${KERNEL_BRANCH:-rpi-6.12.y}"
SRC_DIR="${KERNEL_SRC:-/tmp/rpi-linux-48bit}"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)/out"
JOBS="${JOBS:-$(nproc)}"
CROSS=aarch64-linux-gnu-

command -v "${CROSS}gcc" >/dev/null || { echo "FATAL: ${CROSS}gcc not found"; exit 1; }

echo "==> Source: raspberrypi/linux @ ${BRANCH} (dir: ${SRC_DIR})"
if [ ! -d "${SRC_DIR}/.git" ]; then
  git clone --depth=1 --branch "${BRANCH}" https://github.com/raspberrypi/linux.git "${SRC_DIR}"
else
  git -C "${SRC_DIR}" fetch --depth=1 origin "${BRANCH}"
  git -C "${SRC_DIR}" checkout -q FETCH_HEAD
fi
SHA=$(git -C "${SRC_DIR}" rev-parse --short HEAD)
echo "==> Pinned commit: ${SHA}"

cd "${SRC_DIR}"
export ARCH=arm64 CROSS_COMPILE="${CROSS}"

echo "==> Configure: bcm2711_defconfig + VA_BITS_48 + LOCALVERSION -v8-48bit"
make bcm2711_defconfig
./scripts/config --disable CONFIG_ARM64_VA_BITS_39
./scripts/config --enable  CONFIG_ARM64_VA_BITS_48
./scripts/config --set-str CONFIG_LOCALVERSION "-v8-48bit"
./scripts/config --disable CONFIG_LOCALVERSION_AUTO
make olddefconfig

# The whole point — fail loudly if the choice didn't take.
grep -q '^CONFIG_ARM64_VA_BITS_48=y' .config || { echo "FATAL: VA_BITS_48 not set after olddefconfig"; exit 1; }
grep -q '^CONFIG_ARM64_VA_BITS=48'   .config || { echo "FATAL: ARM64_VA_BITS != 48"; exit 1; }

# No-initramfs boot contract: the custom kernel filename breaks auto_initramfs
# name-matching, so the node boots WITHOUT an initramfs. That is only safe while
# the SD-card rootfs path is built-in. Fail the build if a future defconfig
# demotes any of these to =m (see README "No-initramfs contract").
for opt in CONFIG_MMC_BCM2835 CONFIG_MMC_SDHCI_IPROC CONFIG_EXT4_FS CONFIG_BLK_DEV_SD; do
  grep -q "^${opt}=y" .config || { echo "FATAL: ${opt} is not built-in — no-initramfs boot would fail"; exit 1; }
done

echo "==> Build (-j${JOBS}) — Image + modules"
make -j"${JOBS}" Image modules

KREL=$(make -s kernelrelease)
echo "==> kernelrelease: ${KREL}"
case "${KREL}" in *-v8-48bit*) ;; *) echo "FATAL: unexpected kernelrelease ${KREL}"; exit 1;; esac

STAGE=$(mktemp -d)
trap 'rm -rf "${STAGE}"' EXIT
mkdir -p "${STAGE}/boot" "${STAGE}/modules"
cp arch/arm64/boot/Image "${STAGE}/boot/kernel8-48bit.img"
make INSTALL_MOD_PATH="${STAGE}/modules" INSTALL_MOD_STRIP=1 modules_install >/dev/null
printf '%s\n' "${KREL}" > "${STAGE}/KERNEL_RELEASE"

mkdir -p "${OUT_DIR}"
TARBALL="${OUT_DIR}/rpi-kernel-48bit-${KREL}-${SHA}.tar.gz"
tar -C "${STAGE}" -czf "${TARBALL}" boot modules KERNEL_RELEASE
echo "==> Artifact: ${TARBALL}"
du -h "${TARBALL}"
