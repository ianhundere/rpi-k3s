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
- `quixit.configmap.yml` - ConfigMap for Quixit configuration
- `quixit.secret.yml` - Secrets for Quixit (including OAuth credentials)
- `oauth/oauth2-proxy.deployment.yml` - OAuth2 Proxy deployment
- `oauth/oauth2-proxy.service.yml` - OAuth2 Proxy service
- `setup.sh` - Script to deploy Quixit
- `env-setup.sh` - Script to set up environment variables

## Quick Setup

The easiest way to deploy Quixit is to use the provided scripts:

1. Make the scripts executable:
   ```
   chmod +x env-setup.sh setup.sh
   ```

2. Set up environment variables:
   ```
   ./env-setup.sh
   ```

3. Deploy Quixit:
   ```
   ./setup.sh
   ```

## Manual Setup

If you prefer to set up Quixit manually, follow these steps:

1. Create the namespace:
   ```
   kubectl apply -f quixit.ns.yml
   ```

2. Create the PVC:
   ```
   kubectl apply -f quixit.pvc.yml
   ```

3. Set up environment variables:
   ```
   export QUIXIT_HOST=your-quixit-domain.com
   export GITHUB_CLIENT_ID=your-github-client-id
   export GITHUB_CLIENT_SECRET=your-github-client-secret
   export COOKIE_SECRET=$(openssl rand -base64 32 | tr -- '+/' '-_')
   ```

4. Create the ConfigMap and Secrets:
   ```
   envsubst < quixit.configmap.yml | kubectl apply -f -
   envsubst < quixit.secret.yml | kubectl apply -f -
   ```

5. Deploy OAuth2 Proxy:
   ```
   kubectl apply -f oauth/oauth2-proxy.service.yml
   kubectl apply -f oauth/oauth2-proxy.deployment.yml
   ```

6. Deploy FileBrowser:
   ```
   kubectl apply -f quixit.deployment.yml
   kubectl apply -f quixit.service.yml
   envsubst < quixit.ingress.yml | kubectl apply -f -
   ```

7. Create the admin credentials secret:
   ```
   kubectl create secret generic quixit-admin-credentials \
     --namespace quixit \
     --from-literal=admin-user=admin \
     --from-literal=admin-password=YOUR_ADMIN_PASSWORD
   ```

8. Apply the CronJobs:
   ```
   kubectl apply -f quixit.cronjob.yml
   kubectl apply -f pack-scheduler.yaml
   ```

9. Initialize the Quixit environment:
   ```
   kubectl apply -f quixit-init-job.yaml
   ```

## Setting up GitHub OAuth

1. Go to GitHub Developer Settings: https://github.com/settings/developers
2. Click "New OAuth App"
3. Fill in the application details:
   - Application name: Quixit
   - Homepage URL: https://your-quixit-domain.com
   - Authorization callback URL: https://your-quixit-domain.com/oauth2/callback
4. Register the application
5. Copy the Client ID and generate a Client Secret
6. Use these values for the GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET environment variables

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