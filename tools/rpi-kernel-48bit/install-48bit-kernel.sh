#!/usr/bin/env bash
# Install / activate the 48-bit VA kernel on ONE Raspberry Pi node, safely.
# Run from the workstation (needs: ssh to node, kubectl for drain/uncordon).
#
# Usage:
#   install-48bit-kernel.sh <node> <tarball> stage      # copy kernel + modules onto node (no reboot)
#   install-48bit-kernel.sh <node> <tarball> tryboot    # drain + ONE-SHOT boot the new kernel (falls back to stock on next reset)
#   install-48bit-kernel.sh <node> <tarball> promote    # make kernel= permanent in config.txt + install apt guard + reboot + uncordon
#   install-48bit-kernel.sh <node> <tarball> rollback   # remove kernel= line, reboot back onto stock kernel
#
# Safety model:
# - tryboot.txt is honoured by the Pi firmware for exactly one boot attempt
#   (`reboot '0 tryboot'`); any subsequent reset boots stock config.txt. So a
#   broken kernel strands the node only until a power cycle, never permanently.
# - CAUTION: if the trial kernel HANGS (rather than panics+reboots), the node
#   needs a physical power cycle — drain first, canary on a worker, never start
#   with kube-master.
# - promote appends `kernel=kernel8-48bit.img` to config.txt. apt kernel
#   updates keep writing kernel8.img (unused, harmless, and a always-fresh
#   rollback target); they cannot touch our file.
set -euo pipefail

NODE="${1:?usage: $0 <node> <tarball> stage|tryboot|promote|rollback}"
TARBALL="${2:?missing tarball}"
ACTION="${3:?missing action: stage|tryboot|promote|rollback}"

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 "${NODE}")
FW=/boot/firmware

wait_for_ssh() {
  local tries=60
  echo "==> waiting for ${NODE} to come back (max $((tries*5))s)"
  for _ in $(seq 1 "${tries}"); do
    if ssh -o BatchMode=yes -o ConnectTimeout=3 "${NODE}" true 2>/dev/null; then return 0; fi
    sleep 5
  done
  echo "FATAL: ${NODE} did not return; if the trial kernel hung, power-cycle it (stock kernel boots next)"; return 1
}

krel() { tar -xzOf "${TARBALL}" KERNEL_RELEASE; }

case "${ACTION}" in
stage)
  KREL=$(krel)
  echo "==> staging ${KREL} onto ${NODE}"
  scp -q "${TARBALL}" "${NODE}:/tmp/k48.tar.gz"
  "${SSH[@]}" "
    set -euo pipefail
    sudo tar -C / --no-same-owner -xzf /tmp/k48.tar.gz modules
    sudo mv /modules/lib/modules/${KREL} /lib/modules/ 2>/dev/null || sudo rsync -a /modules/lib/modules/${KREL}/ /lib/modules/${KREL}/
    sudo rm -rf /modules
    tar -xzOf /tmp/k48.tar.gz boot/kernel8-48bit.img | sudo tee ${FW}/kernel8-48bit.img >/dev/null
    rm /tmp/k48.tar.gz
    echo staged: \$(ls -la ${FW}/kernel8-48bit.img); ls -d /lib/modules/${KREL}
  "
  ;;

tryboot)
  KREL=$(krel)
  echo "==> drain ${NODE}"
  kubectl drain "${NODE}" --ignore-daemonsets --delete-emptydir-data --timeout=120s
  echo "==> one-shot tryboot of ${KREL} on ${NODE}"
  "${SSH[@]}" "
    set -euo pipefail
    test -f ${FW}/kernel8-48bit.img
    sudo cp ${FW}/config.txt ${FW}/tryboot.txt
    echo 'kernel=kernel8-48bit.img' | sudo tee -a ${FW}/tryboot.txt >/dev/null
    sudo reboot '0 tryboot'
  " || true   # ssh drops on reboot
  wait_for_ssh
  GOT=$("${SSH[@]}" uname -r)
  if [ "${GOT}" = "${KREL}" ]; then
    echo "==> TRYBOOT OK: ${NODE} is running ${GOT} (one-shot; a plain reboot returns to stock)"
  else
    echo "FATAL: ${NODE} booted ${GOT}, expected ${KREL} — tryboot failed, node is on stock kernel"; exit 1
  fi
  ;;

promote)
  KREL=$(krel)
  GOT=$("${SSH[@]}" uname -r)
  [ "${GOT}" = "${KREL}" ] || { echo "FATAL: refusing to promote — ${NODE} is running ${GOT}, not ${KREL} (run tryboot first)"; exit 1; }
  echo "==> promoting kernel= on ${NODE} + installing apt guard"
  "${SSH[@]}" "
    set -euo pipefail
    grep -q '^kernel=kernel8-48bit.img' ${FW}/config.txt || echo 'kernel=kernel8-48bit.img' | sudo tee -a ${FW}/config.txt >/dev/null
    sudo rm -f ${FW}/tryboot.txt
    # Post-apt guard: warn loudly if the boot pin or the kernel file ever disappears.
    printf 'DPkg::Post-Invoke { \"test -f ${FW}/kernel8-48bit.img && grep -q ^kernel=kernel8-48bit.img ${FW}/config.txt || echo \\\\\"WARNING: 48-bit kernel boot pin is BROKEN — Envoy will crash on this node after next reboot (see rpi-k3s tools/rpi-kernel-48bit)\\\\\" >&2\"; };\n' | sudo tee /etc/apt/apt.conf.d/99-48bit-kernel-guard >/dev/null
    sudo reboot
  " || true
  wait_for_ssh
  GOT=$("${SSH[@]}" uname -r)
  [ "${GOT}" = "${KREL}" ] || { echo "FATAL: after promote, ${NODE} runs ${GOT}"; exit 1; }
  kubectl uncordon "${NODE}"
  echo "==> PROMOTED: ${NODE} permanently on ${KREL}; guard installed; node uncordoned"
  ;;

rollback)
  echo "==> rolling ${NODE} back to stock kernel"
  "${SSH[@]}" "
    set -euo pipefail
    sudo sed -i '/^kernel=kernel8-48bit.img/d' ${FW}/config.txt
    sudo rm -f ${FW}/tryboot.txt /etc/apt/apt.conf.d/99-48bit-kernel-guard
    sudo reboot
  " || true
  wait_for_ssh
  echo "==> ${NODE} back on: $("${SSH[@]}" uname -r)"
  kubectl uncordon "${NODE}" 2>/dev/null || true
  ;;

*) echo "unknown action ${ACTION}"; exit 2 ;;
esac
