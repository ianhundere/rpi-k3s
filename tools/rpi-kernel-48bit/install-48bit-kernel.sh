#!/usr/bin/env bash
# Install / activate the 48-bit VA kernel on ONE Raspberry Pi node, safely.
# Run from the workstation (needs: ssh to node, kubectl for drain/uncordon).
#
# Usage:
#   install-48bit-kernel.sh <node> <tarball> stage      # copy kernel (as TRIAL file) + modules onto node; no reboot
#   install-48bit-kernel.sh <node> <tarball> tryboot    # drain + ONE-SHOT boot the trial kernel
#   install-48bit-kernel.sh <node> <tarball> promote    # trial -> pinned kernel8-48bit.img, config.txt pin, apt guard, reboot, verify, uncordon
#   install-48bit-kernel.sh <node> <tarball> rollback   # remove pin + guard, reboot back onto stock kernel, verify
#
# Safety model:
# - stage NEVER touches a kernel the node currently boots: it writes
#   kernel8-48bit-trial.img (+ a .krel marker). This makes refreshes safe too —
#   the live pinned kernel8-48bit.img is only replaced by promote, after the
#   trial booted successfully.
# - tryboot.txt is honoured by the Pi firmware for exactly ONE boot attempt;
#   any subsequent reset boots config.txt. tryboot also ensures `panic=10` in
#   cmdline.txt so a PANICKING trial kernel self-reboots back onto the stock
#   config. A HUNG kernel still needs a physical power cycle (node is drained
#   first; canary on a worker; kube-master last).
# - Every mutation runs in its own fully-error-checked ssh call; ONLY the bare
#   reboot is allowed to drop the connection. Post-reboot verification checks
#   the actual on-disk boot state, not just uname.
set -euo pipefail

NODE="${1:?usage: $0 <node> <tarball> stage|tryboot|promote|rollback}"
TARBALL="${2:?missing tarball}"
ACTION="${3:?missing action: stage|tryboot|promote|rollback}"

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 "${NODE}")
FW=/boot/firmware
TRIAL_IMG="kernel8-48bit-trial.img"
FINAL_IMG="kernel8-48bit.img"
GUARD=/etc/apt/apt.conf.d/99-48bit-kernel-guard

krel() { tar -xzOf "${TARBALL}" KERNEL_RELEASE; }

wait_for_down() {
  echo "==> waiting for ${NODE} to go DOWN (max 90s)"
  for _ in $(seq 1 18); do
    if ! ssh -o BatchMode=yes -o ConnectTimeout=3 "${NODE}" true 2>/dev/null; then return 0; fi
    sleep 5
  done
  echo "FATAL: ${NODE} never went down — the reboot did not happen; investigate before retrying"; return 1
}

wait_for_up() {
  local tries=60
  echo "==> waiting for ${NODE} to come back (max $((tries*5))s)"
  for _ in $(seq 1 "${tries}"); do
    if ssh -o BatchMode=yes -o ConnectTimeout=3 "${NODE}" true 2>/dev/null; then return 0; fi
    sleep 5
  done
  echo "FATAL: ${NODE} did not return within $((tries*5))s."
  echo "  If the kernel HUNG: power-cycle the node. Which kernel boots next is"
  echo "  determined by ${FW}/config.txt (tryboot is one-shot; stock unless a"
  echo "  kernel= pin was promoted). Node remains cordoned in k3s."
  return 1
}

reboot_node() {
  # The ONLY place a dropped ssh connection is acceptable.
  "${SSH[@]}" "sudo reboot ${1:-}" || true
  wait_for_down
  wait_for_up
}

drain_node() {
  if ! kubectl drain "${NODE}" --ignore-daemonsets --delete-emptydir-data --timeout=120s; then
    echo "FATAL: drain failed (PDB / stuck pod?). Node is now CORDONED but not drained."
    echo "  Fix the eviction blocker and re-run, or 'kubectl uncordon ${NODE}' to abort."
    return 1
  fi
}

case "${ACTION}" in
stage)
  KREL=$(krel)
  echo "==> staging ${KREL} onto ${NODE} (trial file — live kernel untouched)"
  scp -q "${TARBALL}" "${NODE}:/tmp/k48.tar.gz"
  "${SSH[@]}" "
    set -euo pipefail
    sudo rm -rf /tmp/k48-modules && mkdir -p /tmp/k48-modules
    tar -C /tmp/k48-modules -xzf /tmp/k48.tar.gz modules KERNEL_RELEASE
    sudo rsync -a --delete /tmp/k48-modules/modules/lib/modules/${KREL}/ /lib/modules/${KREL}/
    # Atomic-ish kernel write: temp file on the same FAT fs, then rename.
    tar -xzOf /tmp/k48.tar.gz boot/${FINAL_IMG} | sudo tee ${FW}/${TRIAL_IMG}.tmp >/dev/null
    sudo mv ${FW}/${TRIAL_IMG}.tmp ${FW}/${TRIAL_IMG}
    printf '%s\n' '${KREL}' | sudo tee ${FW}/kernel8-48bit-trial.krel >/dev/null
    rm -rf /tmp/k48.tar.gz /tmp/k48-modules
    echo \"staged: \$(ls -la ${FW}/${TRIAL_IMG})\"
    ls -d /lib/modules/${KREL}
  "
  ;;

tryboot)
  KREL=$(krel)
  echo "==> pre-flight: trial marker must match this tarball"
  MARKER=$("${SSH[@]}" "cat ${FW}/kernel8-48bit-trial.krel 2>/dev/null" || true)
  [ "${MARKER}" = "${KREL}" ] || { echo "FATAL: staged trial is '${MARKER}', tarball is '${KREL}' — re-run stage"; exit 1; }
  echo "==> writing tryboot.txt (one-shot) + ensuring panic=10 in cmdline.txt"
  "${SSH[@]}" "
    set -euo pipefail
    test -f ${FW}/${TRIAL_IMG}
    sudo sh -c 'sed \"/^kernel=/d\" ${FW}/config.txt > ${FW}/tryboot.txt'
    echo 'kernel=${TRIAL_IMG}' | sudo tee -a ${FW}/tryboot.txt >/dev/null
    grep -q 'panic=' ${FW}/cmdline.txt || sudo sed -i '1 s/\$/ panic=10/' ${FW}/cmdline.txt
  "
  echo "==> drain + one-shot tryboot of ${KREL} on ${NODE}"
  drain_node
  reboot_node "'0 tryboot'"
  GOT=$("${SSH[@]}" uname -r)
  if [ "${GOT}" = "${KREL}" ]; then
    echo "==> TRYBOOT OK: ${NODE} is running ${GOT} (one-shot; any reset returns to the config.txt kernel)"
    echo "==> validate now (envoy repro uses nodeName so it runs on the cordoned node — see README), then promote"
  else
    echo "FATAL: ${NODE} booted ${GOT}, expected ${KREL} — trial rejected; node is on its config.txt kernel and remains cordoned"
    "${SSH[@]}" "sudo rm -f ${FW}/tryboot.txt"
    exit 1
  fi
  ;;

promote)
  KREL=$(krel)
  GOT=$("${SSH[@]}" uname -r)
  [ "${GOT}" = "${KREL}" ] || { echo "FATAL: refusing to promote — ${NODE} runs ${GOT}, not ${KREL} (run tryboot first)"; exit 1; }
  MARKER=$("${SSH[@]}" "cat ${FW}/kernel8-48bit-trial.krel 2>/dev/null" || true)
  [ "${MARKER}" = "${KREL}" ] || { echo "FATAL: trial marker '${MARKER}' != '${KREL}' — trial was re-staged since tryboot"; exit 1; }

  echo "==> promoting: trial -> ${FINAL_IMG}, pin in config.txt (mutations, fully checked)"
  "${SSH[@]}" "
    set -euo pipefail
    sudo mv ${FW}/${TRIAL_IMG} ${FW}/${FINAL_IMG}
    sudo mv ${FW}/kernel8-48bit-trial.krel ${FW}/kernel8-48bit.krel
    sudo sed -i '/^kernel=/d' ${FW}/config.txt
    echo 'kernel=${FINAL_IMG}' | sudo tee -a ${FW}/config.txt >/dev/null
    grep -q '^kernel=${FINAL_IMG}' ${FW}/config.txt
    sudo rm -f ${FW}/tryboot.txt
  "
  echo "==> installing apt guard (single quoting layer via stdin) + validating apt still parses"
  printf '%s\n' "DPkg::Post-Invoke { \"test -f ${FW}/${FINAL_IMG} && grep -q ^kernel=${FINAL_IMG} ${FW}/config.txt || { echo 'WARNING: 48-bit kernel boot pin is BROKEN - Envoy will crash on this node after next reboot (see rpi-k3s tools/rpi-kernel-48bit)' >&2; logger -p user.err -t 48bit-kernel-guard 'boot pin broken'; }\"; };" \
    | "${SSH[@]}" "sudo tee ${GUARD} >/dev/null"
  "${SSH[@]}" "sudo apt-get check -qq" || { echo "FATAL: apt rejects the guard file — removing it"; "${SSH[@]}" "sudo rm -f ${GUARD}"; exit 1; }

  echo "==> reboot onto the pinned kernel"
  reboot_node
  echo "==> post-reboot verification (on-disk state, not just uname)"
  "${SSH[@]}" "
    set -euo pipefail
    [ \"\$(uname -r)\" = '${KREL}' ]
    grep -q '^kernel=${FINAL_IMG}' ${FW}/config.txt
    test -f ${GUARD} && sudo apt-get check -qq
  " || { echo "FATAL: post-promote verification failed on ${NODE} — node left cordoned"; exit 1; }
  kubectl uncordon "${NODE}"
  echo "==> PROMOTED: ${NODE} permanently on ${KREL}; guard installed and apt-validated; node uncordoned"
  ;;

rollback)
  echo "==> rolling ${NODE} back to stock kernel (drain first)"
  kubectl cordon "${NODE}" >/dev/null 2>&1 || true
  kubectl drain "${NODE}" --ignore-daemonsets --delete-emptydir-data --timeout=120s \
    || echo "WARN: drain incomplete — continuing rollback anyway (emergency path)"
  "${SSH[@]}" "
    set -euo pipefail
    sudo sed -i '/^kernel=/d' ${FW}/config.txt
    sudo rm -f ${FW}/tryboot.txt ${GUARD}
    ! grep -q '^kernel=' ${FW}/config.txt
  "
  reboot_node
  GOT=$("${SSH[@]}" uname -r)
  case "${GOT}" in
    *-48bit*) echo "FATAL: ${NODE} still runs ${GOT} after rollback — investigate; node left cordoned"; exit 1 ;;
    *)        echo "==> ROLLBACK OK: ${NODE} on stock ${GOT}" ;;
  esac
  kubectl uncordon "${NODE}"
  ;;

*) echo "unknown action ${ACTION}"; exit 2 ;;
esac
