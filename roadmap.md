# Feature: Multi-Repository Sync Support

## Summary
Extend ha-kopia to support replication of the primary repository to multiple remote destinations (WebDAV, S3, SFTP, Azure, GCS, etc.) with optional automatic scheduling.

## Motivation
Users often need a 3-2-1 backup strategy:
- **Primary**: Local repository in HAOS (`/share`)
- **Secondary #1**: Local backup (RPi NAS, external drive, etc.)
- **Secondary #2**: Remote cloud storage (O2 Cloud via WebDAV, AWS S3, Backblaze, etc.)

Currently, ha-kopia supports only a single repository. Users must:
- Run separate tools (rclone, rsync) to replicate snapshots
- Manage external orchestration scripts
- Lose Kopia's deduplication benefits on secondary destinations

## Solution
Leverage Kopia's native `kopia repository sync-to` command to support configurable remote repositories as sync destinations.

### Key Design Principles
- **Provider-agnostic**: Supports any backend Kopia supports (WebDAV, S3, SFTP, Azure, GCS, B2, etc.)
- **Community-friendly**: No hardcoded dependencies on specific cloud providers
- **Non-invasive**: Changes isolated to config + sync logic; primary snapshot workflow unchanged
- **Simple UX**: YAML array in add-on config; automatic cron scheduling optional

## Implementation

### Configuration (config.yaml)
```yaml
# Existing options (unchanged)
backup_media: "/share"
repository_subdir: "kopia-repository"
snapshot_paths:
  - "/backup"
server_username: "kopia"
password: null

# New: Sync destinations (optional)
sync_to_repositories:
  - name: "webdav-o2cloud"
    type: "webdav"
    url: "http://192.168.1.100:8080/dav"
    username: "user@example.com"
    password: ""
    enabled: true

  - name: "s3-backblaze"
    type: "s3"
    bucket: "my-backups"
    prefix: "kopia"
    endpoint: "s3.us-west-000.backblazeb2.com"
    access_key: ""
    secret_key: ""
    enabled: false

  - name: "sftp-external"
    type: "sftp"
    host: "backup.example.com"
    path: "/kopia-backups"
    username: "backup-user"
    password: ""
    enabled: false

# Automatic sync scheduling (cron format, optional)
sync_schedule: "0 3 * * *"  # Daily at 3 AM
sync_enabled: false         # Disable cron if manual only
```

### Schema (config.yaml schema)
```yaml
schema:
  # Existing fields
  backup_media: str
  repository_subdir: str
  snapshot_paths:
    - str
  server_username: str
  password: password?

  # New fields
  sync_to_repositories:
    - name: str
      type: select(webdav, s3, sftp, azure, gcs, b2)
      url: str?                    # WebDAV
      bucket: str?                 # S3, GCS
      prefix: str?                 # S3, GCS
      endpoint: str?               # S3 custom endpoint (Backblaze, etc.)
      host: str?                   # SFTP
      path: str?                   # SFTP, local filesystem
      username: str?
      password: password?
      access_key: str?             # S3
      secret_key: password?        # S3
      account_name: str?           # Azure
      account_key: password?       # Azure
      project_id: str?             # GCS
      credentials_json: password?  # GCS
      enabled: bool?

  sync_schedule: str?
  sync_enabled: bool?
```

### Backend Changes (run.sh)
1. After primary repository creation/connection and initial snapshot, parse `sync_to_repositories` config
2. For each enabled repository:
   - Construct Kopia URL from config (e.g., `webdav://url`, `s3://bucket`, `sftp://...`)
   - Execute: `kopia repository sync-to <url> --password=$PASSWORD`
3. If `sync_enabled: true`, install cron job to run sync periodically
4. Log results to addon logs (sync duration, bandwidth, errors)

### Example Use Cases

**O2 Cloud (WebDAV Gateway)**
```yaml
sync_to_repositories:
  - name: "o2cloud"
    type: "webdav"
    url: "http://192.168.1.100:8081/dav"
    enabled: true
sync_schedule: "0 3 * * *"
sync_enabled: true
```

**Backblaze B2 + AWS S3**
```yaml
sync_to_repositories:
  - name: "backblaze-b2"
    type: "s3"
    bucket: "my-b2-bucket"
    endpoint: "s3.us-west-000.backblazeb2.com"
    access_key: "..."
    secret_key: "..."
    enabled: true
  
  - name: "aws-s3-glacier"
    type: "s3"
    bucket: "my-aws-bucket"
    access_key: "..."
    secret_key: "..."
    enabled: false  # Manual only
```

**SFTP to NAS**
```yaml
sync_to_repositories:
  - name: "nas-external"
    type: "sftp"
    host: "nas.local"
    path: "/backups/kopia"
    username: "backup"
    password: "..."
    enabled: true
sync_schedule: "0 4 * * *"
sync_enabled: true
```

## Benefits
- ✅ True 3-2-1 backup with single tool
- ✅ Deduplication applied to secondary destinations
- ✅ No external script dependencies
- ✅ Secure credential handling via Home Assistant
- ✅ Community extensible (any Kopia backend)
- ✅ Minimal UI friction (array config in YAML)

## Testing
- Test sync to WebDAV (local + remote)
- Test S3 variants (AWS, Backblaze, MinIO, Wasabi)
- Test SFTP
- Verify deduplication across sync boundaries
- Verify cron scheduling and logs
- Error handling (network failure, auth, disk full)

## Migration / Breaking Changes
**None.** This feature is 100% backward-compatible:
- If `sync_to_repositories` is empty or missing, addon behaves exactly as today
- Existing configs continue to work without modification

## Effort Estimate
- Config schema & validation: ~1h
- run.sh sync logic: ~2h
- Testing: ~2h
- Documentation: ~1h
- **Total: ~6h**

## Related Issues/Discussions
- Kopia documentation: [Sync command](https://kopia.io/docs/reference/command-line/common/sync-to/)

---

**Labels**: `enhancement`, `feature-request`, `roadmap`  
**Priority**: Medium (enables popular 3-2-1 backup strategy without external tools)
