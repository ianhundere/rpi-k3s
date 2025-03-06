# quixit

a music collaboration challenge where participants upload samples, then create songs using those samples.

## overview

kubernetes resources for automating the quixit music collaboration challenge using filebrowser with a file-watcher sidecar that enforces phase rules and file type restrictions.

## phases

quixit operates in sequential phases, with each challenge numbered sequentially (quixit-1, quixit-2, etc.):

1. **samples phase** (7 days)
   - users upload audio samples to the `samples` directory
   - only audio files (.wav, .mp3, .ogg, .flac, .aiff) are allowed
   - uploads to other locations are automatically removed
   - phase ends automatically on monday at 00:00 or via manual transition

2. **songs phase** (12 days)
   - samples are archived into `SAMPLE_PACK.tar.gz` for download
   - samples directory becomes read-only
   - users download samples and create songs
   - users upload completed songs to the `songs` directory
   - uploads to other locations are automatically removed
   - phase ends automatically on saturday at 00:00 or via manual finalization
   - deadline for song submission is friday before midnight

3. **completed phase**
   - songs are archived into `ALL_SONGS.tar.gz` for download
   - entire challenge directory becomes read-only
   - all content remains available for download

## timeline

- **monday 00:00** - new challenge created (7-day sample submission)
- **next monday 00:00** - sample submission ends, song submission begins (12-day window)
- **friday before midnight** - deadline for song submissions
- **saturday 00:00** - challenge finalized and made read-only

## automation

- cronjobs handle automatic phase transitions
- file-watcher enforces rules in real-time:
  - no uploads to the root directory
  - no uploads directly to quixit folders
  - only uploads to samples directory during sample phase
  - only uploads to songs directory during song phase
  - no uploads to completed quixits
- logs are stored persistently for monitoring

## manual operations

```shell
# create new challenge
kubectl apply -f automation/manual-create-quixit.yaml

# transition to songs phase
kubectl apply -f automation/manual-transition-to-songs.yaml

# finalize challenge
kubectl apply -f automation/manual-finalize-quixit.yaml

# view logs
kubectl exec -n quixit <pod-name> -c file-watcher -- cat /logs/watcher.log
kubectl exec -n quixit <pod-name> -c quixit -- cat /logs/filebrowser.log
```

## directory structure

```text
/quixit/
  └── quixit-<number>/
      ├── QUIXIT_HAS_BEGUN_UPLOAD_SAMPLES_BEFORE_<date>.txt  # samples phase
      ├── SUBMIT_SONGS_BEFORE_<date>.txt                     # songs phase
      ├── QUIXIT_COMPLETE_ARCHIVE_AVAILABLE.txt              # completed phase
      ├── SAMPLE_PACK.tar.gz                                 # created after samples phase
      ├── ALL_SONGS.tar.gz                                   # created after songs phase
      ├── samples/                                           # for sample uploads
      └── songs/                                             # for song uploads
```
