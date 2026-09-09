---
status: proposed
date: 2026-09-09
---

# config/ is applied by hand, not by flux

## Context

`config/cluster-vars.yaml` and `config/cluster-secrets.enc.yaml` are the two objects every `${VAR}` in the repo resolves against. flux could own them (the apps kustomization already decrypts with sops), but they have always been applied by hand with `kubectl apply --server-side --force-conflicts`, and the repo carries a readme warning, an annotation-strip recipe and `tools/audit-sops-drift.sh` to police that one step.

## Decision

recorded as the current state, not endorsed: the manual step stays until the owner decides whether it is a deliberate human gate on secret rollout or an accident of history. the candidate replacement is a `config` flux kustomization with sops decryption that `infrastructure` depends on, plus `StrictPostBuildSubstitutions` so an undefined `${VAR}` fails the reconcile instead of rendering empty. it is on the architecture review list.

## Consequences

- until decided, every edit to `config/` needs the server-side apply; plain `kubectl apply` writes the decrypted values into the last-applied annotation.
- the guardrails exist only because this seam is manual. adopting the candidate retires the readme section and both passes of the audit tool and concentrates the behaviour in the reconciler (locality, leverage).
- reopen when the owner answers the gate question; supersede if the candidate lands.
