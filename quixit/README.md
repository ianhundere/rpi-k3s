# Quixit - Music Collaboration Challenge

Quixit is a weekly music collaboration challenge where participants upload samples, then create songs using those samples.

## Overview

This directory contains Kubernetes resources for automating the Quixit music collaboration challenge using FileBrowser.

The automation handles:
- Creating a new Quixit challenge folder each week
- Managing the sample submission phase
- Transitioning to the song submission phase
- Finalizing each challenge and making it read-only

## Workflow

1. Every Friday at midnight, a new `quixit-<week_number>` folder is created
2. Users upload samples to the `samples` folder until Monday
3. On Monday at midnight, the samples are zipped into a sample pack
4. Users download the sample pack and upload songs to the `songs` folder until Friday
5. On Friday, the challenge is finalized and made read-only

## Files

- `quixit.ns.yml` - Creates the Quixit namespace
- `quixit.pvc.yml` - Persistent volume claim for storing files
- `quixit.deployment.yml` - FileBrowser deployment
- `quixit.service.yml` - FileBrowser service
- `quixit.ingress.yml` - Ingress for accessing FileBrowser
- `quixit.cronjob.yml` - CronJobs for automating the Quixit workflow
- `pack-scheduler.yaml` - Initializes the Quixit directory structure
- `quixit-init-job.yaml` - One-time job to initialize the Quixit environment
- `quixit-phase-transition-job.yaml` - Manual job to force phase transitions

## Setup

1. Create the namespace:
   ```
   kubectl apply -f quixit.ns.yml
   ```

2. Create the PVC:
   ```
   kubectl apply -f quixit.pvc.yml
   ```

3. Deploy FileBrowser:
   ```
   kubectl apply -f quixit.deployment.yml
   kubectl apply -f quixit.service.yml
   kubectl apply -f quixit.ingress.yml
   ```

4. Create the admin credentials secret:
   ```
   kubectl create secret generic quixit-admin-credentials \
     --namespace quixit \
     --from-literal=admin-user=admin \
     --from-literal=admin-password=YOUR_ADMIN_PASSWORD
   ```

5. Apply the CronJobs:
   ```
   kubectl apply -f quixit.cronjob.yml
   kubectl apply -f pack-scheduler.yaml
   ```

6. Initialize the Quixit environment:
   ```
   kubectl apply -f quixit-init-job.yaml
   ```

## Manual Operations

### Force Phase Transition

To manually transition from samples to songs phase:
```
kubectl apply -f quixit-phase-transition-job.yaml
```

To manually finalize a Quixit challenge:
```
kubectl create job --from=cronjob/quixit-manual-phase-transition quixit-finalize-now -n quixit --overrides '{"spec":{"template":{"spec":{"containers":[{"name":"phase-transition","env":[{"name":"PHASE","value":"finalize"}]}]}}}}'
```

## File Structure

Each Quixit challenge follows this structure:
```
/quixit/
  ├── WELCOME_TO_QUIXIT_MUSIC_COLLABORATION_CHALLENGE.txt
  └── quixit-<week_number>/
      ├── QUIXIT_HAS_BEGUN_UPLOAD_SAMPLES_BEFORE_<date>.txt (during sample phase)
      ├── SUBMIT_SONGS_BEFORE_<date>.txt (during song phase)
      ├── QUIXIT_COMPLETE_ARCHIVE_AVAILABLE.txt (when complete)
      ├── SAMPLE_PACK.zip (created after sample phase)
      ├── ALL_SONGS.zip (created after song phase)
      ├── samples/
      └── songs/
``` 