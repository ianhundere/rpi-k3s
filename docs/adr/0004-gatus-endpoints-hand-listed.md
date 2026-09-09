---
status: accepted
date: 2026-09-09
---

# gatus endpoints are listed by hand

## Context

gatus watches 22 endpoints from one configmap. generating that list from the httproutes and services in the repo was considered so that adding a host cannot forget its check.

## Decision

the endpoint list stays hand-written in `apps/gatus/configmap.yml`. adding a public host includes adding its endpoint; the readme carries the checklist.

## Consequences

- the configmap is already one module with a small interface (name, url, conditions). a generator would add a build step and lose the per-endpoint judgement: plex answering 401 is healthy, the acme port-80 check wants a 301, internal twins split app-down from ingress-down.
- the entries pass the deletion test: remove the file and the same judgements reappear somewhere else.
- a config change needs a pod delete after reconcile; gatus validates strictly, so a typo crashloops the new pod - revert and delete again.
