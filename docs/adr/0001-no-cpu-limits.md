---
status: accepted
date: 2026-09-09
---

# no cpu limits; memory request equals limit

## Context

the pis have four slow cores and 4gb. cpu limits are enforced by cfs quota, which throttles a container even while cores sit idle - latency spikes on hardware with none to spare. the protection actually wanted is against one container eating a node's memory.

## Decision

every container sets memory request == limit and no cpu limit (cpu requests only, for scheduling), with the one exemption recorded below. stateful containers (postgres, mongo, the arrs) get at least 1Gi because 512Mi silently ooms after weeks of working-set creep. pods therefore sit in the burstable qos class on purpose.

## Consequences

- oom protection comes from `oom_score_adj`, which request == limit alone sets; guaranteed qos would only change eviction ordering.
- one rule for every container: a size change is one edit with no second knob to keep consistent (locality).
- `tools/audit-flux-tiers.sh` asserts the rule for the flux controllers; nothing yet asserts it for `apps/`. a manifest lint is the open candidate.
- one exemption: the envoy data plane runs 256Mi request / 1Gi limit in `infrastructure/envoy-gateway/envoyproxy.yml`. its tcmalloc drifts upward over weeks, so the limit is a ceiling to survive, not a working set; it is paired with the weekly pod recycle in `infrastructure/envoy-gateway/cronjob-rotate.yml`, which resets allocator state before the ceiling is reached. neither half works alone - do not "fix" the request up to the limit, and do not drop the cronjob.
- do not "fix" burstable qos by adding cpu limits.
