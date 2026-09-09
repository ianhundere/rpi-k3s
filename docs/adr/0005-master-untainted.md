---
status: accepted
date: 2026-09-09
---

# kube-master carries no taint

## Context

since 2026-08-03 the control plane runs on the amd64 beelink (8gb, etcd on its internal ssd) and the former master pi rejoined as kube-worker4. unifi (controller plus mongo, 3Gi requested) and the heavier postgres pods fit on no 4gb pi.

## Decision

the master is untainted and schedules ordinary workloads. `k3s-config/k3s_server-config.yml` sets no node-taint, and the ansible bootstrap must not add one.

## Consequences

- the master is also the only node with failover headroom: a pi failure rehomes onto it, a master failure takes the control plane and unifi down together.
- the system-upgrade-controller plans keep their master tolerations; they are harmless without the taint.
- anything that re-adds `node-role.kubernetes.io/master:NoSchedule` strands unifi and postgres on a rebuild.
