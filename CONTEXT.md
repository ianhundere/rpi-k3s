# rpi-k3s

the vocabulary of one flux-managed k3s homelab: what the manifests, commit messages and ops notes mean by each name. one context.

## Language

**shared-gateway**:
The single Gateway every public hostname enters through. One listener pair (http and https) per host; a route attaches to a listener by name.
_Avoid_: ingress, internal-gateway, load balancer

**static PV**:
A PersistentVolume hand-written for one workload, pointing at a directory that already exists on the nas; the PVC binds to it by name, so data never moves. Reclaim is always retain.
_Avoid_: dynamic PV, provisioned volume

**media-config**:
The shared read-write-many volume every media app mounts a subdirectory of, for its config and small state. Its siblings media-data (movies, tv, downloads) and music-data (the music library) are separate nas volumes with different backup guarantees.
_Avoid_: config PVC, nfs share

**media-postgres**:
The one Postgres instance the arrs (sonarr, radarr, prowlarr, lidarr) share, each with its own databases.
_Avoid_: sqlite, arr database

**image policy marker**:
The comment on an image line that names the ImagePolicy allowed to rewrite it. Only marked lines under apps are ever bumped.
_Avoid_: image tag annotation

**flux-image-updates**:
The branch image automation commits bumps to; a pull request is opened from it daily. It is fully derivable from the policies, so deleting it loses nothing.
_Avoid_: automation branch, bot branch

**vpn-gated pod**:
A pod whose app shares its network namespace with a gluetun sidecar, so all traffic leaves through the vpn tunnel. prowlarr, qbittorrent and soulseek (the workload is named soulseek everywhere; slskd is only the image it runs).
_Avoid_: vpn container, proxy pod

**port-sync sidecar**:
The loop beside a vpn-gated pod that reads the port the vpn provider forwarded and tells the app to listen on it.
_Avoid_: port forwarder

**cluster-vars / cluster-secrets**:
The two hand-applied objects flux reads to fill every `${VAR}` in a manifest: cluster-vars holds hostnames and lan addresses in plaintext, cluster-secrets holds everything sensitive and lives in git only encrypted.
_Avoid_: env file, values

**house resource tier**:
The sizing rule every container follows: memory request equals limit, no cpu limit, stateful containers at least 1Gi, probe timeouts the pis can meet.
_Avoid_: guaranteed qos, resource quota

## Seams

Where behaviour can be swapped without editing the caller. Each is the interface of a module; a seam earns a name only when two adapters sit at it, and these five have them.

**storage seam**:
The PVC name. A workload asks for a claim; which static PV or storage class answers is decided beside the PV, not in the deployment.

**ingress seam**:
The listener name on shared-gateway (`sectionName`). A route names the listener it wants; hostnames, certs and ports belong to the gateway.

**config seam**:
The `${VAR}` key. A manifest names a key; cluster-vars and cluster-secrets are the two adapters that supply it.

**upgrade seam**:
The image policy marker. A deployment names the policy; the policy decides which tags qualify.

**port-sync seam**:
The app api the port-sync loop calls. qbittorrent and soulseek are its two adapters; today they are two copies of the same loop rather than one module.
