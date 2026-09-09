---
status: accepted
date: 2026-09-09
---

# image automation objects stay in one place

## Context

each app's `image:` line carries a marker naming an ImagePolicy, and the ImageRepository/ImagePolicy pairs live together under `infrastructure/image-automation/`. co-locating them into each app dir was considered so that an app dir is self-contained.

## Decision

keep every ImageRepository and ImagePolicy in `infrastructure/image-automation/`. the marker on the image line is the seam; an app dir only names a policy.

## Consequences

- the deletion test says moving the objects would move complexity, not concentrate it: the linuxserver exclusion list repeats across six repositories and kustomize has no inheritance to share it, so per-app copies would drift.
- policies are reviewed and bumped in one file; a range change is one edit (locality), and one scan-interval convention covers every registry.
- the marker-to-policy consistency check belongs in a manifest lint, not in the layout.
