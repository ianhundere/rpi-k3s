---
status: accepted
date: 2026-10-10
---

# the stateful 1gi floor is a default; a soaked peak can override it

## Context

0001 gives stateful containers at least 1Gi because 512Mi silently ooms after weeks of working-set creep. applied to everything with no evidence, the floor left the arm64 workers 88% requested at ~35% used, with free memory in slivers. nothing 1Gi-shaped fit anywhere, and sonarr sat Pending 5d22h after a restart. a 14-day per-container soak (`apps/capacity-recorder/`, 5-minute samples, 2026-09-25 to 10-09) supplied the peaks the floor had been standing in for.

## Decision

the floor stays the default for anything without evidence. a container, a database included, goes below it only on a 14-day recorded peak that is <=512Mi and not still rising. the request is then max(peak x 1.5, peak + 256Mi) rounded up to 64Mi, or peak x 2 for databases. postgres never goes below 256Mi, which covers the 128MB default shared_buffers. the rule is applied only to containers requesting >=512Mi; smaller ones are not worth the churn. memory request == limit still holds.

a container keeps its current request when:
- it is rising: week-two slope above max(10% of peak, 16Mi)/week;
- it caps itself in-process: a jvm `MEM_LIMIT`, a mongo wiredtiger cache, or a go `GOMEMLIMIT`;
- or its peak is >=95% of its limit, unless `memory.stat` shows that reading is page cache.

## Consequences

- `kubectl top` reports the working set, which counts active page cache, so a reading pinned at the limit with no oom is usually cache, not demand. check `memory.stat` anon before acting on it. qbittorrent read 1012/1024Mi with 33Mi anon and went to 512Mi.
- each container below the floor carries a one-line manifest comment citing its peak. as of 2026-10-10 those are media-postgres 960Mi, slskd 640Mi, qbittorrent 512Mi, tufkin-postgres 256Mi, and prowlarr 448Mi, which was already under the floor.
- a cut can make a pod fit a pi, where it then eats the headroom the cut was meant to free. tufkin-postgres and prowlarr prefer kube-master by node affinity for that reason.
- 5-minute sampling cannot see a brief excursion, and cgroup v2 kills on breach with no grace period. restart-watch alerts on any oomkill, and a container that ooms goes back to its previous size.
- do not raise these back to 1Gi to "match the convention"; re-soak instead.
