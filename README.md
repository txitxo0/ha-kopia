# ha-kopia

[![Open your Home Assistant instance and show the add add-on repository dialog with a specific repository URL pre-filled.](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https://github.com/txitxo0/ha-kopia)

Add-on repository for Home Assistant OS with a Kopia add-on.

## Structure

- `repository.yaml`: add-on repository metadata.
- `kopia/`: Kopia add-on.

## What this add-on does

- Runs Kopia inside Home Assistant OS.
- Exposes the web UI on direct port `51515`.
- Uses `/share` storage as the repository destination.
- Validates that the configured media path exists.
- If the path does not exist, it logs the media found under `/share`.

## Supported architectures

- `amd64` (x86_64, suitable for Intel N100).
- `aarch64` (64-bit ARM).

No 32-bit architectures are included.

## Add-on options

- `backup_media`: media path, must be under `/share`.
- `repository_subdir`: repository folder inside the selected media.
- `snapshot_paths`: paths to back up.
- `sync_enabled`: enables scheduled repository syncs.
- `sync_schedule`: cron expression used when scheduled syncs are enabled.
- `sync_to_repositories`: optional list of secondary repositories that receive a Kopia `repository sync-to` from the primary Home Assistant repository.
- `server_username`: username used to access the Kopia web UI.
- `password`: Kopia repository password.

## UI limitation

Home Assistant add-ons do not provide a dynamic selector for paths discovered at runtime. Because of that:

- `backup_media` is a text field.
- if the path is invalid, the script logs the available media under `/share`.

## Setup

1. Publish this repository on GitHub.
2. In Home Assistant, go to Settings -> Add-ons -> Add-on Store -> Repositories.
3. Add the repository URL.
4. Install the `Kopia` add-on.
5. Configure `backup_media` (for example `/share`, `/share/nas`, or `/share/usb`).
6. Set `repository_subdir`, `snapshot_paths`, `server_username`, and `password`.
7. Start the add-on.
8. Open the UI using `http://HAOS_IP:51515`.
9. Check the logs if something fails.

## Kopia notifications in Home Assistant

Kopia does not expose a usable JSON payload in the webhook by default, but notification templates allow custom headers and a custom body. The add-on seeds `snapshot-report.txt` and `test-notification.txt` templates into the repository the first time it starts, using `application/x-www-form-urlencoded` so Home Assistant receives structured data.

Recommended flow:

1. In Kopia, create a notification profile of type `webhook`.
2. Set `Minimum severity` to `error` to send only real failures.
3. Use the Home Assistant webhook as the endpoint, for example `http://YOUR_HA:8123/api/webhook/kopia-ha-backup`.
4. The add-on initially creates the `snapshot-report.txt` template in the repository with content like this:

```txt
Subject: {{ .EventArgs.OverallStatus }}
Content-Type: application/x-www-form-urlencoded

title={{ urlquery "Kopia backup" }}&message={{ urlquery .EventArgs.OverallStatus }}&severity={{ urlquery .EventArgs.OverallStatusCode }}
```

5. You can later adjust that template from the Kopia UI if you want to change the wording.
6. In Home Assistant, create a webhook-triggered automation and read `trigger.data.title`, `trigger.data.message`, and `trigger.data.severity`.

If you use Kopia's "Test notification" button, the seeded `test-notification.txt` template is also form-encoded, so Home Assistant receives the same fields in `trigger.data`.

Example automation:

```yaml
alias: Kopia backup error
description: Show Kopia failures as a persistent notification
triggers:
  - trigger: webhook
    webhook_id: kopia-ha-backup
    allowed_methods:
      - POST
    local_only: true

conditions: []

actions:
  - action: persistent_notification.create
    data:
      notification_id: kopia_backup
      title: "{{ trigger.data.title }}"
      message: "{{ trigger.data.message }}"

mode: queued
max: 10
```

With this, Kopia still generates the notification, but Home Assistant receives it in a format it can display and process without an external middleware.

## Example configuration

```yaml
backup_media: /share/nas
repository_subdir: kopia-repository
snapshot_paths:
  - /backup
sync_to_repositories:
  - name: o2cloud
    type: webdav
    url: http://192.168.1.100:8081/dav
    username: user@example.com
    password: change-webdav-password
    must_exist: true
    parallel: 2
    enabled: true

  - name: backblaze-secondary
    type: s3
    bucket: my-b2-bucket
    endpoint: s3.us-west-000.backblazeb2.com
    access_key: your-access-key
    secret_key: your-secret-key
    prefix: kopia/
    delete: false
    enabled: false

  - name: local-second-copy
    type: filesystem
    path: /share/usb/kopia-secondary
    delete: true
    parallel: 4
    enabled: true
sync_enabled: true
sync_schedule: 0 3 * * *
server_username: kopia
password: change-this-password
```

## Multi-repository sync

The primary repository remains the Home Assistant repository configured with `backup_media` and `repository_subdir`.

You can now add any number of additional sync destinations from the add-on UI by appending entries to `sync_to_repositories`. Each destination declares its own backend type and only the fields relevant to that backend are used:

- `filesystem`: `path`
- `webdav`: `url`, optionally `username`, `password`
- `s3`: `bucket`, optionally `endpoint`, `region`, `prefix`, `access_key`, `secret_key`
- `sftp`: `host`, `path`, `username`, optionally `port`, `password`
- `azure`: `container`, `account_name`, optionally `account_key`, `sas_token`, `storage_domain`, `prefix`
- `gcs`: `bucket`, optionally `prefix`, `credentials_json`
- `b2`: `bucket`, `key_id`, `key`, optionally `prefix`

Current behavior in this first implementation:

- the add-on creates or connects the primary repository exactly as before
- it creates the initial snapshot exactly as before
- after that, it runs `kopia repository sync-to` once for each enabled destination
- if `sync_enabled: true`, it also installs a real cron schedule inside the add-on and runs the same sync cycle automatically
- sync failures are logged as warnings and do not block the Kopia server startup
- overlapping sync cycles are skipped with a warning instead of running concurrently

This keeps the add-on provider-agnostic and already covers cases like a local WebDAV gateway that uploads to O2 Cloud, without hardcoding any vendor-specific flow.

Each destination can now also tune a few native Kopia sync flags:

- `delete`: pass `--delete` to remove blobs that no longer exist in the source repository
- `must_exist`: pass `--must-exist` to require that the destination repository is already initialized
- `parallel`: pass `--parallel` to control copy concurrency
- `update`: if set to `false`, pass `--no-update`

Extra runtime validation added in this iteration:

- `filesystem` and `sftp` paths must be absolute
- `webdav` URLs must start with `http://` or `https://`
- `s3` requires `access_key` and `secret_key` together when either is set
- `azure` requires `account_key` or `sas_token`
- `gcs` requires `credentials_json` in this add-on environment

## O2 Cloud example

For your concrete case, if you have a local WebDAV gateway on your network that writes to O2 Cloud, the add-on config can look like this:

```yaml
backup_media: /share
repository_subdir: kopia-repository
snapshot_paths:
  - /backup

sync_enabled: true
sync_schedule: 0 */6 * * *

sync_to_repositories:
  - name: o2cloud-webdav
    type: webdav
    url: http://192.168.1.100:8081/dav
    username: tu-usuario
    password: tu-password-webdav
    must_exist: true
    parallel: 2
    update: true
    enabled: true

server_username: kopia
password: una-password-larga-y-distinta
```

Notes for this setup:

- `password` is the Kopia repository password, not the WebDAV password
- `must_exist: true` is a good default once the remote repository has already been created
- if the WebDAV gateway is slow or has limited CPU, keep `parallel` low, usually `1` or `2`
- if the remote endpoint is brand new, set `must_exist: false` for the first sync so Kopia can initialize it

## Roadmap

- Add ingress access


## Acknowledgements

Thanks to the Kopia team for building and maintaining this excellent backup project:

- [kopia/kopia: Cross-platform backup tool for Windows, macOS & Linux with fast, incremental backups, client-side end-to-end encryption, compression and data deduplication. CLI and GUI included.](https://github.com/kopia/kopia)